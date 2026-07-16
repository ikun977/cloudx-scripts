#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=true
REBOOT=false
FORCE_SERVER=false
REMOVE_CLOUDX=true
REMOVE_DOCKER=true
REMOVE_GPU=true
PURGE_BUILD_DEPS=false
AUTO_REMOVE=true
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

usage() {
  cat <<'EOF'
用法：
  sudo bash reset-agent-install-test-host.sh [选项]

把一台专用 CloudX Agent 测试机清理回接近“从 0 安装”的状态，用于验证后台一键安装脚本。
默认只打印将执行的操作；真正删除必须加 --yes。

会清理：
  - CloudX Agent 服务、二进制、配置、Node Token、数据和日志目录
  - CloudX/Docker 容器运行数据，以及 docker.io/containerd/runc 等包
  - NVIDIA Container Toolkit 包、apt 源和 keyring
  - NVIDIA 驱动相关包、CloudX GPU 安装日志和 nouveau blacklist

默认不会清理 curl、gnupg、ca-certificates、pciutils、kmod、dkms、build-essential、linux headers
这类通用基础包；需要更接近全新系统时可额外加 --purge-build-deps。

选项：
      --yes               真正执行删除；没有该参数时只 dry-run
      --reboot            清理完成后重启。卸载 GPU 驱动后建议重启
      --keep-cloudx       保留 CloudX Agent 文件和服务
      --keep-docker       保留 Docker 包和 /var/lib/docker
      --keep-gpu          保留 NVIDIA 驱动和 NVIDIA Container Toolkit
      --purge-build-deps  额外卸载 GPU 安装脚本拉起的构建/诊断包
      --no-autoremove     不执行 apt-get autoremove/purge
      --force-server      即使检测到 cloudx-server.service 也继续
  -h, --help              显示帮助

示例：
  sudo bash reset-agent-install-test-host.sh
  sudo bash reset-agent-install-test-host.sh --yes
  sudo bash reset-agent-install-test-host.sh --yes --reboot
  sudo bash reset-agent-install-test-host.sh --yes --keep-docker

注意：
  这是破坏性脚本，只应在专用 Agent 测试机上运行。
  默认会删除 Docker 数据目录，机器上的所有 Docker 容器、镜像、卷都会丢失。
EOF
}

log() {
  printf '[reset-agent-install-test-host] %s\n' "$*"
}

die() {
  printf '[reset-agent-install-test-host] ERROR: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes)
        DRY_RUN=false
        shift
        ;;
      --reboot)
        REBOOT=true
        shift
        ;;
      --keep-cloudx)
        REMOVE_CLOUDX=false
        shift
        ;;
      --keep-docker)
        REMOVE_DOCKER=false
        shift
        ;;
      --keep-gpu)
        REMOVE_GPU=false
        shift
        ;;
      --purge-build-deps)
        PURGE_BUILD_DEPS=true
        shift
        ;;
      --no-autoremove)
        AUTO_REMOVE=false
        shift
        ;;
      --force-server)
        FORCE_SERVER=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数：$1（使用 --help 查看帮助）"
        ;;
    esac
  done
}

run() {
  if [ "$DRY_RUN" = true ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return
  fi
  "$@"
}

run_sh() {
  if [ "$DRY_RUN" = true ]; then
    printf '+ sh -c %q\n' "$*"
    return
  fi
  sh -c "$*"
}

require_root_and_linux() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行，例如 sudo bash reset-agent-install-test-host.sh"
  [ "$(uname -s)" = "Linux" ] || die "只支持 Linux"
  [ -f /etc/os-release ] || die "无法识别操作系统：缺少 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:13*|ubuntu:24.04*) ;;
    *) die "只支持 Debian 13 或 Ubuntu 24.04，当前是 ${ID:-unknown} ${VERSION_ID:-unknown}" ;;
  esac
}

guard_not_control_plane() {
  if [ "$FORCE_SERVER" = true ]; then
    return
  fi
  if systemctl list-unit-files --no-legend cloudx-server.service 2>/dev/null | grep -q '^cloudx-server\.service' ||
    systemctl status cloudx-server.service >/dev/null 2>&1; then
    die "检测到 cloudx-server.service。为避免误清主控机，请确认是 Agent 测试机后加 --force-server"
  fi
}

safe_rm_rf() {
  local target="$1"
  local allowed=false
  [ -n "$target" ] || die "拒绝删除空路径"
  case "$target" in
    /etc/cloudx|/etc/cloudx/*) allowed=true ;;
    /var/lib/cloudx-agent|/var/lib/cloudx-agent/*) allowed=true ;;
    /var/log/cloudx-agent|/var/log/cloudx-agent/*) allowed=true ;;
    /var/log/cloudx-gpu-install.log) allowed=true ;;
    /etc/systemd/system/cloudx-agent.service) allowed=true ;;
    /usr/local/bin/cloudx|/usr/local/bin/cloudx.rollback) allowed=true ;;
    /var/lib/docker|/var/lib/docker/*) allowed=true ;;
    /var/lib/containerd|/var/lib/containerd/*) allowed=true ;;
    /etc/docker|/etc/docker/*) allowed=true ;;
    /etc/systemd/system/docker.service.d|/etc/systemd/system/docker.service.d/*) allowed=true ;;
    /etc/apt/sources.list.d/nvidia-container-toolkit.list) allowed=true ;;
    /etc/apt/sources.list.d/nvidia-container-toolkit.sources) allowed=true ;;
    /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg) allowed=true ;;
    /etc/nvidia-container-runtime|/etc/nvidia-container-runtime/*) allowed=true ;;
    /etc/modprobe.d/cloudx-blacklist-nouveau.conf) allowed=true ;;
    /etc/apt/sources.list.d/cuda*.list) allowed=true ;;
    /usr/share/keyrings/cuda-archive-keyring.gpg) allowed=true ;;
    /etc/apt/preferences.d/cuda*) allowed=true ;;
  esac
  [ "$allowed" = true ] || die "拒绝删除未列入白名单的路径：$target"
  if [ -e "$target" ] || [ -L "$target" ]; then
    run rm -rf -- "$target"
  fi
}

installed_packages_matching() {
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
    grep -E "$1" |
    sort -u || true
}

purge_packages() {
  local reason="$1"
  shift
  local packages=("$@")
  if [ "${#packages[@]}" -eq 0 ]; then
    log "$reason：无已安装包"
    return
  fi
  log "$reason：${packages[*]}"
  run apt-get purge -y "${packages[@]}"
}

stop_cloudx_agent() {
  log "停止并删除 CloudX Agent"
  run systemctl stop cloudx-agent.service || true
  run systemctl disable cloudx-agent.service || true
  safe_rm_rf /etc/systemd/system/cloudx-agent.service
  run systemctl daemon-reload || true
  run systemctl reset-failed cloudx-agent.service || true
  safe_rm_rf /usr/local/bin/cloudx
  safe_rm_rf /usr/local/bin/cloudx.rollback
  safe_rm_rf /etc/cloudx
  safe_rm_rf /var/lib/cloudx-agent
  safe_rm_rf /var/log/cloudx-agent
}

stop_cloudx_containers() {
  if ! command -v docker >/dev/null 2>&1; then
    return
  fi
  if ! docker info >/dev/null 2>&1; then
    return
  fi
  local ids
  ids="$(docker ps -aq --filter label=cloudx.managed=true 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    run_sh "docker rm -f $ids"
  fi
  ids="$(docker ps -aq --filter 'name=cloudx-' 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    run_sh "docker rm -f $ids"
  fi
}

remove_docker() {
  log "清理 Docker 和容器数据"
  stop_cloudx_containers
  run systemctl stop docker.service || true
  run systemctl stop containerd.service || true

  mapfile -t docker_packages < <(installed_packages_matching '^(docker|docker.io|docker-ce|docker-ce-cli|docker-ce-rootless-extras|docker-buildx-plugin|docker-compose|docker-compose-v2|docker-compose-plugin|containerd|containerd.io|runc)$')
  purge_packages "卸载 Docker 包" "${docker_packages[@]}"

  safe_rm_rf /var/lib/docker
  safe_rm_rf /var/lib/containerd
  safe_rm_rf /etc/docker
  safe_rm_rf /etc/systemd/system/docker.service.d
  run systemctl daemon-reload || true
}

remove_gpu_stack() {
  log "清理 NVIDIA Container Toolkit"
  run systemctl stop nvidia-persistenced.service || true
  mapfile -t toolkit_packages < <(installed_packages_matching '^(nvidia-container-toolkit|nvidia-container-toolkit-base|nvidia-container-runtime|nvidia-docker2|libnvidia-container[0-9-]*|libnvidia-container-tools|nvidia-ctk)$')
  purge_packages "卸载 NVIDIA Container Toolkit 包" "${toolkit_packages[@]}"
  safe_rm_rf /etc/apt/sources.list.d/nvidia-container-toolkit.list
  safe_rm_rf /etc/apt/sources.list.d/nvidia-container-toolkit.sources
  safe_rm_rf /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  safe_rm_rf /etc/nvidia-container-runtime

  log "清理 NVIDIA 驱动包"
  mapfile -t driver_packages < <(installed_packages_matching '^(nvidia-|libnvidia-|libcuda1$|xserver-xorg-video-nvidia|firmware-nvidia-|firmware-misc-nonfree$|ubuntu-drivers-common$|cuda-drivers|cuda-toolkit|cuda-keyring|cuda-[0-9]|nsight-|opencl-nvidia)')
  purge_packages "卸载 NVIDIA 驱动/CUDA 相关包" "${driver_packages[@]}"

  safe_rm_rf /etc/modprobe.d/cloudx-blacklist-nouveau.conf
  safe_rm_rf /var/log/cloudx-gpu-install.log
  run_sh "rm -f /etc/apt/sources.list.d/cuda*.list /etc/apt/preferences.d/cuda* /usr/share/keyrings/cuda-archive-keyring.gpg"
  if command -v update-initramfs >/dev/null 2>&1; then
    run update-initramfs -u || true
  fi
}

remove_build_deps() {
  if [ "$PURGE_BUILD_DEPS" != true ]; then
    return
  fi
  log "清理可选构建/诊断依赖"
  mapfile -t build_packages < <(installed_packages_matching '^(dkms|build-essential|mokutil|pciutils)$|^linux-headers-')
  purge_packages "卸载构建/诊断包" "${build_packages[@]}"
}

apt_cleanup() {
  if [ "$AUTO_REMOVE" != true ]; then
    return
  fi
  log "执行 apt autoremove/autoclean"
  run apt-get autoremove --purge -y
  run apt-get autoclean
}

print_plan() {
  log "运行模式：$([ "$DRY_RUN" = true ] && printf 'dry-run' || printf '执行删除')"
  log "CloudX Agent：$REMOVE_CLOUDX"
  log "Docker：$REMOVE_DOCKER"
  log "NVIDIA/GPU：$REMOVE_GPU"
  log "构建依赖：$PURGE_BUILD_DEPS"
  log "apt autoremove：$AUTO_REMOVE"
  log "完成后重启：$REBOOT"
  if [ "$DRY_RUN" = true ]; then
    log "当前只是预览。确认无误后加 --yes 真正执行。"
  else
    log "即将删除 Agent 测试机依赖。请确认这不是生产主控或承载其他 Docker 服务的机器。"
  fi
}

main() {
  parse_args "$@"
  require_root_and_linux
  guard_not_control_plane
  print_plan

  if [ "$REMOVE_CLOUDX" = true ]; then
    stop_cloudx_agent
  fi
  if [ "$REMOVE_DOCKER" = true ]; then
    remove_docker
  fi
  if [ "$REMOVE_GPU" = true ]; then
    remove_gpu_stack
  fi
  remove_build_deps
  apt_cleanup

  log "清理完成。卸载 GPU 驱动后通常需要重启，重启后再跑后台生成的一键安装命令。"
  if [ "$REBOOT" = true ]; then
    run systemctl reboot
  fi
}

main "$@"
