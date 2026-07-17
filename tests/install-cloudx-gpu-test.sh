#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# Load function definitions without executing the installer entrypoint.
source <(sed '/^main "\$@"$/d' "$ROOT/install-cloudx-gpu.sh")
trap - ERR

assert_accepts() {
  local function_name="$1" value="$2"
  if ! printf '%s\n' "$value" | "$function_name"; then
    printf 'expected %s to accept: %s\n' "$function_name" "$value" >&2
    exit 1
  fi
}

assert_rejects() {
  local function_name="$1" value="$2"
  if printf '%s\n' "$value" | "$function_name"; then
    printf 'expected %s to reject: %s\n' "$function_name" "$value" >&2
    exit 1
  fi
}

assert_accepts gpu_pci_is_supported 'NVIDIA Corporation TU104GL [Tesla T4] [10de:1eb8]'
assert_accepts gpu_pci_is_supported 'NVIDIA Corporation GA102GL [A10G] [10de:2237]'
assert_accepts gpu_pci_is_supported 'NVIDIA Corporation AD102GL [L20] [10de:26ba]'
assert_rejects gpu_pci_is_supported 'NVIDIA Corporation Unknown [10de:ffff]'

assert_accepts gpu_name_is_supported 'Tesla T4'
assert_accepts gpu_name_is_supported 'NVIDIA A10G'
assert_accepts gpu_name_is_supported 'NVIDIA L20'
assert_rejects gpu_name_is_supported 'NVIDIA GeForce RTX 4090'

printf 'install-cloudx-gpu tests passed\n'
