#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

MIN_DRIVER_MAJOR="${MIN_DRIVER_MAJOR:-550}"
NVIDIA_DRIVER_PACKAGE="${NVIDIA_DRIVER_PACKAGE:-}"
VERIFY_IMAGE="${VERIFY_IMAGE:-ubuntu:24.04}"
AUTO_REBOOT="${AUTO_REBOOT:-false}"
CLOUDX_GPU_PROMPT_REBOOT="${CLOUDX_GPU_PROMPT_REBOOT:-true}"
LOG_FILE="${LOG_FILE:-/var/log/cloudx-gpu-install.log}"
VERIFY_ONLY=false
REBOOT_REQUIRED=false
KERNEL_REBOOT_REQUIRED=false
OS_ID=""
OS_VERSION=""
SUPPORTED_GPU_PCI_PATTERN='10de:(1eb8|2237|26ba)'
SUPPORTED_GPU_NAME_PATTERN='Tesla T4|A10G|NVIDIA L20'
SUPPORTED_GPU_DESCRIPTION='T4, A10G, and L20'

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-cloudx-gpu.sh
  sudo ./install-cloudx-gpu.sh --verify-only

Options:
  --verify-only  Do not install packages; verify the existing GPU stack only.
  -h, --help     Show this help.

Environment:
  AUTO_REBOOT=true                  Reboot without prompting when a reboot is required.
  CLOUDX_GPU_PROMPT_REBOOT=false    Do not prompt; let the caller handle reboot.
  MIN_DRIVER_MAJOR=550              Minimum accepted NVIDIA driver major version.
  NVIDIA_DRIVER_PACKAGE=<package>   Override the distribution-selected driver package.
  VERIFY_IMAGE=ubuntu:24.04         Image used for the Docker GPU verification.
  LOG_FILE=/var/log/...             Installation log path.
EOF
}

timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '[%s] [cloudx-gpu] %s\n' "$(timestamp)" "$*"; }
warn() { printf '[%s] [cloudx-gpu] WARNING: %s\n' "$(timestamp)" "$*" >&2; }
fail() { printf '[%s] [cloudx-gpu] ERROR: %s\n' "$(timestamp)" "$*" >&2; exit 1; }

on_error() {
  local status=$?
  printf '[%s] [cloudx-gpu] ERROR: command failed at line %s: %s\n' \
    "$(timestamp)" "${BASH_LINENO[0]}" "${BASH_COMMAND}" >&2
  exit "$status"
}
trap on_error ERR

is_true() {
  case "${1,,}" in
    true|1|yes) return 0 ;;
    false|0|no) return 1 ;;
    *) fail "expected a boolean value, got: $1" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --verify-only)
      VERIFY_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

require_root() {
  [ "$(id -u)" -eq 0 ] || fail "run this script as root (use sudo)"
}

start_logging() {
  install -d -m 0755 "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 0644 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

detect_platform() {
  [ "$(uname -s)" = "Linux" ] || fail "only Linux is supported"
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) fail "only linux/amd64 is supported" ;;
  esac
  [ -f /etc/os-release ] || fail "cannot detect the operating system"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION="${VERSION_ID:-}"
  case "${OS_ID}:${OS_VERSION}" in
    debian:13*|ubuntu:24.04*) ;;
    *) fail "supported systems: Debian 13 or Ubuntu 24.04" ;;
  esac
  log "platform: ${OS_ID} ${OS_VERSION}, $(uname -m), kernel $(uname -r)"
}

apt_get() {
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o DPkg::Lock::Timeout=300 "$@"
}

rewrite_if_changed() {
  local source="$1" candidate="$2"
  if ! cmp -s "$source" "$candidate"; then
    install -m 0644 "$candidate" "$source"
    log "enabled Debian non-free repositories in $source"
  fi
  rm -f "$candidate"
}

enable_debian_driver_repositories() {
  local source candidate
  if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    source=/etc/apt/sources.list.d/debian.sources
    candidate="$(mktemp)"
    awk '
      /^[[:space:]]*Components:/ {
        for (key in seen) delete seen[key]
        for (i = 2; i <= NF; i++) seen[$i] = 1
        line = $0
        if (!seen["contrib"]) line = line " contrib"
        if (!seen["non-free"]) line = line " non-free"
        if (!seen["non-free-firmware"]) line = line " non-free-firmware"
        print line
        next
      }
      { print }
    ' "$source" > "$candidate"
    rewrite_if_changed "$source" "$candidate"
  fi

  if [ -f /etc/apt/sources.list ]; then
    source=/etc/apt/sources.list
    candidate="$(mktemp)"
    awk '
      /^[[:space:]]*deb(-src)?[[:space:]]/ && /(deb\.debian\.org|security\.debian\.org)/ {
        for (key in seen) delete seen[key]
        for (i = 1; i <= NF; i++) seen[$i] = 1
        line = $0
        if (!seen["contrib"]) line = line " contrib"
        if (!seen["non-free"]) line = line " non-free"
        if (!seen["non-free-firmware"]) line = line " non-free-firmware"
        print line
        next
      }
      { print }
    ' "$source" > "$candidate"
    rewrite_if_changed "$source" "$candidate"
  fi
}

install_base_packages() {
  if [ "$OS_ID" = "debian" ]; then
    enable_debian_driver_repositories
  fi
  apt_get update
  apt_get install -y --no-install-recommends \
    ca-certificates curl gnupg pciutils kmod dkms build-essential mokutil
  install_kernel_headers
}

package_is_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

install_kernel_headers() {
  local running_kernel exact_headers
  local -a fallback_packages
  running_kernel="$(uname -r)"
  exact_headers="linux-headers-${running_kernel}"
  if package_is_available "$exact_headers"; then
    apt_get install -y --no-install-recommends "$exact_headers"
    return
  fi

  warn "headers for the running kernel are unavailable: $exact_headers"
  case "${OS_ID}:${running_kernel}" in
    debian:*-cloud-amd64)
      fallback_packages=(linux-image-cloud-amd64 linux-headers-cloud-amd64)
      ;;
    debian:*-amd64)
      fallback_packages=(linux-image-amd64 linux-headers-amd64)
      ;;
    ubuntu:*-aws)
      fallback_packages=(linux-aws)
      ;;
    ubuntu:*-generic)
      fallback_packages=(linux-generic)
      ;;
    *)
      fail "no supported kernel meta-package mapping for: ${OS_ID} ${running_kernel}"
      ;;
  esac
  for package in "${fallback_packages[@]}"; do
    package_is_available "$package" || fail "required kernel package is unavailable: $package"
  done
  log "installing current kernel and headers: ${fallback_packages[*]}"
  apt_get install -y "${fallback_packages[@]}"
  KERNEL_REBOOT_REQUIRED=true
  REBOOT_REQUIRED=true
}

assert_supported_gpu() {
  local devices
  command -v lspci >/dev/null 2>&1 || fail "lspci is required"
  devices="$(lspci -nn -d 10de: 2>/dev/null || true)"
  [ -n "$devices" ] || fail "no NVIDIA PCI device was detected"
  printf '%s\n' "$devices"
  if ! gpu_pci_is_supported <<<"$devices"; then
    fail "unsupported NVIDIA GPU; CloudX currently supports $SUPPORTED_GPU_DESCRIPTION"
  fi
}

gpu_pci_is_supported() {
  grep -Eiq "$SUPPORTED_GPU_PCI_PATTERN"
}

gpu_name_is_supported() {
  grep -Eiq "$SUPPORTED_GPU_NAME_PATTERN"
}

secure_boot_notice() {
  if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    warn "Secure Boot is enabled; the NVIDIA kernel module may require key enrollment"
  fi
}

driver_version() {
  nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | sed -n '1p' | tr -d '[:space:]'
}

driver_is_healthy() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

driver_meets_minimum() {
  local version major
  version="$(driver_version)"
  [ -n "$version" ] || return 1
  major="${version%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [ "$major" -ge "$MIN_DRIVER_MAJOR" ]
}

write_nouveau_blacklist() {
  cat >/etc/modprobe.d/cloudx-blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
  update-initramfs -u
}

select_ubuntu_driver_package() {
  local package
  if [ -n "$NVIDIA_DRIVER_PACKAGE" ]; then
    printf '%s\n' "$NVIDIA_DRIVER_PACKAGE"
    return
  fi
  package="$(ubuntu-drivers devices 2>/dev/null |
    sed -nE 's/.*driver[[:space:]]*:[[:space:]]*([^[:space:]]+).*recommended.*/\1/p' |
    sed -n '1p')"
  [ -n "$package" ] || fail "ubuntu-drivers did not report a recommended NVIDIA package"
  printf '%s\n' "$package"
}

install_driver() {
  local package
  log "installing the NVIDIA host driver"
  write_nouveau_blacklist
  case "$OS_ID" in
    ubuntu)
      apt_get install -y --no-install-recommends ubuntu-drivers-common
      package="$(select_ubuntu_driver_package)"
      log "selected Ubuntu driver package: $package"
      apt_get install -y "$package"
      ;;
    debian)
      package="${NVIDIA_DRIVER_PACKAGE:-nvidia-driver}"
      log "selected Debian driver package: $package"
      apt_get install -y "$package" firmware-misc-nonfree
      ;;
  esac
  if lsmod | grep -q '^nouveau'; then
    warn "nouveau is currently loaded and will be disabled after reboot"
    REBOOT_REQUIRED=true
  fi
  if ! modprobe nvidia >/dev/null 2>&1; then
    REBOOT_REQUIRED=true
  fi
}

ensure_driver() {
  if driver_is_healthy && driver_meets_minimum; then
    log "NVIDIA driver $(driver_version) is already healthy"
    return
  fi
  if driver_is_healthy; then
    warn "NVIDIA driver $(driver_version) is older than required major $MIN_DRIVER_MAJOR"
  else
    log "a healthy NVIDIA driver is not currently loaded"
  fi
  install_driver
  if ! driver_is_healthy || ! driver_meets_minimum; then
    REBOOT_REQUIRED=true
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "installing Docker"
    apt_get install -y docker.io
  fi
  systemctl enable --now docker
  docker info >/dev/null 2>&1 || fail "Docker daemon is not available"
  log "Docker is available: $(docker version --format '{{.Server.Version}}')"
}

install_container_toolkit() {
  local key_tmp list_tmp
  log "installing NVIDIA Container Toolkit"
  install -d -m 0755 /usr/share/keyrings
  key_tmp="$(mktemp)"
  list_tmp="$(mktemp)"
  curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
    https://nvidia.github.io/libnvidia-container/gpgkey -o "$key_tmp"
  gpg --dearmor --yes --output /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg "$key_tmp"
  rm -f "$key_tmp"
  curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
    https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o "$list_tmp"
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    "$list_tmp" >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  rm -f "$list_tmp"
  apt_get update
  apt_get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  nvidia-ctk config --set nvidia-container-runtime.mode=legacy --in-place
  systemctl restart docker
  docker info >/dev/null 2>&1 || fail "Docker did not recover after NVIDIA runtime configuration"
}

verify_host_driver() {
  local names
  driver_is_healthy || return 1
  driver_meets_minimum || return 1
  names="$(nvidia-smi --query-gpu=name --format=csv,noheader)"
  gpu_name_is_supported <<<"$names" || fail "the loaded driver reports an unsupported GPU: $names"
  log "host GPU verification passed"
  nvidia-smi --query-gpu=name,uuid,driver_version,memory.total --format=csv,noheader
}

verify_container_runtime() {
  command -v nvidia-ctk >/dev/null 2>&1 || fail "nvidia-ctk is not installed"
  log "verifying GPU access and NVIDIA graphics/video libraries inside Docker"
  docker pull "$VERIFY_IMAGE" >/dev/null
  docker run --rm --runtime=nvidia \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics,display,video \
    "$VERIFY_IMAGE" sh -ec '
      nvidia-smi -L
      for pattern in libnvidia-glcore.so. libnvidia-glsi.so. libnvidia-tls.so.; do
        if ! ldconfig -p | grep -Fq "$pattern"; then
          echo "missing NVIDIA library: $pattern" >&2
          exit 1
        fi
        echo "found NVIDIA library: $pattern"
      done
      libraries="libEGL_nvidia.so.0 libGLX_nvidia.so.0 libnvidia-encode.so.1"
      for library in $libraries; do
        path="$(ldconfig -p | awk -v name="$library" '\''$1 == name { print $NF; exit }'\'')"
        if [ -z "$path" ]; then
          echo "missing NVIDIA library: $library" >&2
          exit 1
        fi
        if ldd "$path" | grep -Eq "libnvidia[^[:space:]]*[[:space:]]+=>[[:space:]]+not found"; then
          echo "$library NVIDIA dependency is missing" >&2
          ldd "$path" >&2
          exit 1
        fi
        echo "found NVIDIA library: $library"
      done
    '
  log "Docker GPU verification passed"
}

verify_only() {
  command -v lspci >/dev/null 2>&1 || fail "pciutils is not installed"
  assert_supported_gpu
  verify_host_driver || fail "NVIDIA host driver verification failed"
  command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
  docker info >/dev/null 2>&1 || fail "Docker daemon is not available"
  verify_container_runtime
  log "CloudX GPU host verification completed successfully"
}

prompt_reboot() {
  if is_true "$AUTO_REBOOT"; then
    log "AUTO_REBOOT=true; rebooting now"
    systemctl reboot
    return
  fi
  if ! is_true "$CLOUDX_GPU_PROMPT_REBOOT"; then
    warn "a reboot is required before GPU verification"
    return
  fi
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '\n需要重启才能继续完成 NVIDIA 驱动加载。\n' >/dev/tty
    printf '按回车确认重启，按 Ctrl+C 取消重启。' >/dev/tty
    read -r _ </dev/tty
    log "reboot confirmed by operator"
    systemctl reboot
    return
  fi
  warn "a reboot is required, but no interactive terminal is available"
  warn "run: sudo reboot"
}

finish_install() {
  if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=true
  fi
  if [ "$REBOOT_REQUIRED" = true ]; then
    if [ "$KERNEL_REBOOT_REQUIRED" = true ]; then
      warn "the repository no longer provides headers for the running kernel"
      warn "a current kernel and matching headers were installed"
    else
      warn "installation finished, but a reboot is required before GPU verification"
    fi
    warn "after reboot, rerun the same installation command"
    prompt_reboot
    return
  fi
  verify_host_driver || fail "NVIDIA host driver verification failed"
  verify_container_runtime
  if systemctl list-unit-files nvidia-persistenced.service >/dev/null 2>&1; then
    systemctl enable --now nvidia-persistenced.service >/dev/null 2>&1 || true
  fi
  nvidia-smi -pm ENABLED >/dev/null 2>&1 || true
  log "CloudX GPU dependencies installed and verified successfully"
}

main() {
  require_root
  if is_true "$AUTO_REBOOT"; then :; else :; fi
  [[ "$MIN_DRIVER_MAJOR" =~ ^[0-9]+$ ]] || fail "MIN_DRIVER_MAJOR must be an integer"
  start_logging
  detect_platform
  log "mode: $([ "$VERIFY_ONLY" = true ] && printf verify-only || printf install)"
  if [ "$VERIFY_ONLY" = true ]; then
    verify_only
    return
  fi
  install_base_packages
  assert_supported_gpu
  secure_boot_notice
  if [ "$KERNEL_REBOOT_REQUIRED" = true ]; then
    finish_install
    return
  fi
  ensure_driver
  ensure_docker
  install_container_toolkit
  finish_install
}

main "$@"
