# CloudX Scripts

CloudX 服务器初始化和运维脚本库。

## 当前支持范围

- CPU 架构：`linux/amd64`
- 操作系统：Debian 13、Ubuntu 24.04
- GPU：NVIDIA Tesla T4、NVIDIA A10G
- 容器运行时：Docker + NVIDIA Container Toolkit

当前不支持其他 Linux 发行版或其他 GPU 型号，也不保留旧安装方式的兼容逻辑。

## 一键安装

在新的 GPU 服务器上直接复制执行：

```bash
sudo apt-get update && sudo apt-get install -y curl && curl -fsSL https://raw.githubusercontent.com/ikun977/cloudx-scripts/main/install-cloudx-gpu.sh | sudo bash
```

如果脚本提示需要重启，重启服务器后重新执行同一条安装命令。脚本会从当前系统状态继续，并完成剩余安装和验收：

```bash
curl -fsSL https://raw.githubusercontent.com/ikun977/cloudx-scripts/main/install-cloudx-gpu.sh | sudo bash
```

脚本会依次完成：

1. 校验操作系统、CPU 架构和 GPU 型号。
2. 安装内核头文件、DKMS 和 NVIDIA 驱动。
3. 安装并启动 Docker。
4. 安装 NVIDIA Container Toolkit，并配置 Docker GPU Runtime。
5. 验证宿主机驱动、容器 GPU、EGL、GLX 和 NVENC 动态库。

需要允许脚本在驱动安装后自动重启时执行：

```bash
curl -fsSL https://raw.githubusercontent.com/ikun977/cloudx-scripts/main/install-cloudx-gpu.sh | sudo env AUTO_REBOOT=true bash
```

默认要求 NVIDIA 驱动主版本不低于 550。需要指定发行版中的驱动包时，可以执行：

```bash
curl -fsSL https://raw.githubusercontent.com/ikun977/cloudx-scripts/main/install-cloudx-gpu.sh | sudo env NVIDIA_DRIVER_PACKAGE=nvidia-driver-570-server bash
```

完整日志保存在 `/var/log/cloudx-gpu-install.log`。

只检查现有环境、不安装软件时执行：

```bash
curl -fsSL https://raw.githubusercontent.com/ikun977/cloudx-scripts/main/install-cloudx-gpu.sh | sudo bash -s -- --verify-only
```

## 验收结果

安装成功必须同时满足：

- `nvidia-smi` 能识别 T4 或 A10G。
- Docker 能通过 `--gpus all` 访问 GPU。
- GPU 容器中存在 `libEGL_nvidia.so.0`。
- GPU 容器中存在 `libGLX_nvidia.so.0`。
- GPU 容器中存在 `libnvidia-encode.so.1`。

这些检查通过后，服务器才具备安装 CloudX GPU Agent 的基础条件。Chrome NVIDIA Renderer 和实际 NVENC 编码仍由 CloudX Agent 准入检查负责。
