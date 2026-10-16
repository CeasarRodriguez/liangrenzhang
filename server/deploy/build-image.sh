#!/usr/bin/env bash
# 在 Mac 上构建服务端镜像，并把它和 Caddy 镜像一起导出成 tar.gz，
# 用于上传到服务器（服务器不需要访问 Docker Hub）。
#
# 用法：build-image.sh <版本号> [平台]
#   例：./build-image.sh 1.0.0 linux/amd64     # 服务器 uname -m 是 x86_64
#       ./build-image.sh 1.0.0 linux/arm64     # 服务器 uname -m 是 aarch64
#
# 需要：Go、Docker（colima 等均可）。
# 程序在本机交叉编译，基础镜像由本机直接下载（crane），所以 Docker 虚拟机本身
# 不需要能访问外网。
# 产物在项目根目录 dist/images/ 下，请长期保存，回滚和迁移都用得到。
set -euo pipefail

VERSION=${1:?用法: build-image.sh <版本号> [linux/amd64|linux/arm64]}
PLATFORM=${2:-linux/amd64}
ARCH=${PLATFORM#linux/}

DEPLOY_DIR=$(cd "$(dirname "$0")" && pwd)
SERVER_DIR=$(dirname "$DEPLOY_DIR")
OUT_DIR=$(dirname "$SERVER_DIR")/dist/images
mkdir -p "$OUT_DIR"

ENV_FILE="$DEPLOY_DIR/.env"
[[ -f $ENV_FILE ]] || ENV_FILE="$DEPLOY_DIR/.env.example"
CADDY_IMAGE=$(grep -E '^CADDY_IMAGE=' "$ENV_FILE" | cut -d= -f2-)
RUNTIME_IMAGE=$(grep -E '^ARG RUNTIME_IMAGE=' "$SERVER_DIR/Dockerfile" | cut -d= -f2-)

crane() {
  if type -P crane >/dev/null 2>&1; then
    command crane "$@"
  else
    go run github.com/google/go-containerregistry/cmd/crane@v0.22.1 "$@"
  fi
}

image_file() { echo "$OUT_DIR/$(echo "$1" | tr ':/' '__')_${ARCH}.tar"; }

# fetch an image for the target platform on this machine and load it into Docker
ensure_image() {
  local ref=$1 tar
  tar=$(image_file "$ref")
  if [[ ! -f $tar.gz ]]; then
    echo ">> 下载 $ref ($PLATFORM)"
    crane pull --platform "$PLATFORM" "$ref" "$tar"
    gzip -f "$tar"
  fi
  gunzip -c "$tar.gz" | docker load -q
}

echo ">> 编译服务端 linux/$ARCH"
(cd "$SERVER_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" \
  go build -trimpath -ldflags "-s -w" -o .build/couple-ledger . &&
  CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" \
  go build -trimpath -ldflags "-s -w" -o .build/relay ./cmd/relay)

ensure_image "$RUNTIME_IMAGE"
ensure_image "$CADDY_IMAGE"

IMAGE="couple-ledger-server:$VERSION"
echo ">> 构建 $IMAGE"
docker buildx build --platform "$PLATFORM" --pull=false --tag "$IMAGE" --load "$SERVER_DIR"

server_tar="$OUT_DIR/couple-ledger-server_${VERSION}_${ARCH}.tar.gz"
docker save --platform "$PLATFORM" "$IMAGE" | gzip > "$server_tar"
echo ">> 已导出："
ls -lh "$server_tar" "$(image_file "$CADDY_IMAGE").gz"
