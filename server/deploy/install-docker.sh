#!/usr/bin/env bash
# 在 Ubuntu 服务器上安装 Docker Engine + Compose 插件（使用阿里云镜像源）。
#
# 用法（在服务器上以 root 执行）：
#   bash install-docker.sh            # 只装 Docker
#   bash install-docker.sh --ufw      # 同时开启 ufw 防火墙，只放行 SSH(22) 和 8443
#
# 注意：如果你的 SSH 不是 22 端口，请不要加 --ufw，或先手动放行你的 SSH 端口。
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "请用 root 运行（sudo bash install-docker.sh）" >&2; exit 1; }
. /etc/os-release
[[ $ID == ubuntu ]] || { echo "这个脚本只支持 Ubuntu，当前是 $ID" >&2; exit 1; }

MIRROR=${DOCKER_MIRROR:-https://mirrors.aliyun.com/docker-ce}

if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  if curl -fsI "$MIRROR/linux/ubuntu/dists/$VERSION_CODENAME/Release" >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "$MIRROR/linux/ubuntu/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $MIRROR/linux/ubuntu $VERSION_CODENAME stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  else
    # Docker's repo has no packages for this Ubuntu release yet: use Ubuntu's own
    echo ">> Docker 官方源暂不支持 Ubuntu ${VERSION_ID}，改用 Ubuntu 自带的 Docker"
    apt-get install -y docker.io docker-compose-v2
  fi
fi

systemctl enable --now docker
docker version --format '>> Docker {{.Server.Version}} 已就绪'
docker compose version

if [[ ${1:-} == --ufw ]]; then
  apt-get install -y ufw
  ufw allow 22/tcp
  ufw allow 8443/tcp
  ufw --force enable
  ufw status
fi

echo ">> 完成。别忘了在云厂商控制台的安全组里放行 TCP 8443。"
echo ">> CPU 架构：$(uname -m)（x86_64 用 linux/amd64 构建镜像，aarch64 用 linux/arm64）"
