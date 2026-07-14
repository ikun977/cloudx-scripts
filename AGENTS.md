# AGENTS.md

## Scope

- This repository contains operational scripts for CloudX hosts.
- Supported GPU hosts are `linux/amd64`, Debian 13 or Ubuntu 24.04, with an NVIDIA T4 or A10G.
- Scripts must be idempotent, fail fast, and provide an explicit post-install verification path.

## Development Policy

- CloudX is in active development. Do not preserve historical installers, old distributions, legacy configuration formats, or temporary compatibility paths.
- Update scripts directly for the current deployment contract.
- Do not silently continue after a failed driver, Docker, NVIDIA runtime, graphics-library, or NVENC-library check.
- Before committing, state whether the change introduces compatibility logic.

