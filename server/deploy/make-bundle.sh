#!/usr/bin/env bash
# 在 Mac 上打一个「服务器安装包」：镜像、配置、证书和安装脚本都在一个文件里，
# 适合用云厂商网页终端上传后在服务器上一条命令安装（不需要从 Mac SSH）。
#
# 用法：make-bundle.sh <服务器IP> [版本号] [平台]
#   例：./make-bundle.sh 1.2.3.4 1.0.0 linux/amd64
#
# - 第一次会为这个 IP 签发服务器证书（用已有根证书），并从 .env.example 生成 .env。
# - 镜像需先用 build-image.sh 构建。
# 产物：dist/bundle/couple-ledger-<版本>.tar.gz
set -euo pipefail

HOST=${1:?用法: make-bundle.sh <服务器IP> [版本号] [平台]}
VERSION=${2:-1.0.0}
PLATFORM=${3:-linux/amd64}
ARCH=${PLATFORM#linux/}

DEPLOY_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$(dirname "$DEPLOY_DIR")")
IMAGES_DIR=$ROOT/dist/images
CERTS=$DEPLOY_DIR/data/certs

# config
if [[ ! -f $DEPLOY_DIR/.env ]]; then
  cp "$DEPLOY_DIR/.env.example" "$DEPLOY_DIR/.env"
fi
sed -i.bak -e "s/^LEDGER_HOST=.*/LEDGER_HOST=$HOST/" -e "s/^LEDGER_VERSION=.*/LEDGER_VERSION=$VERSION/" "$DEPLOY_DIR/.env"
rm -f "$DEPLOY_DIR/.env.bak"

# server certificate for this host
if [[ ! -f $CERTS/server.crt ]] || ! openssl x509 -in "$CERTS/server.crt" -noout -checkip "$HOST" 2>/dev/null | grep -q 'does match'; then
  "$DEPLOY_DIR/gen-certs.sh" "$CERTS" "$HOST"
fi

CADDY_IMAGE=$(grep -E '^CADDY_IMAGE=' "$DEPLOY_DIR/.env" | cut -d= -f2-)
server_tar="$IMAGES_DIR/couple-ledger-server_${VERSION}_${ARCH}.tar.gz"
caddy_tar="$IMAGES_DIR/$(echo "$CADDY_IMAGE" | tr ':/' '__')_${ARCH}.tar.gz"
for f in "$server_tar" "$caddy_tar"; do
  [[ -f $f ]] || { echo "找不到镜像文件 ${f}，请先运行 build-image.sh $VERSION $PLATFORM" >&2; exit 1; }
done

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/couple-ledger"
mkdir -p "$app/images" "$app/data/certs" "$app/secrets"
cp "$DEPLOY_DIR/docker-compose.yml" "$DEPLOY_DIR/Caddyfile" "$DEPLOY_DIR/.env" \
   "$DEPLOY_DIR/backup.sh" "$DEPLOY_DIR/install-docker.sh" "$DEPLOY_DIR/setup.sh" "$app/"
cp "$server_tar" "$caddy_tar" "$app/images/"
cp "$CERTS/server.crt" "$CERTS/server.key" "$CERTS/ca.crt" "$app/data/certs/"
if compgen -G "$DEPLOY_DIR/secrets/*" > /dev/null; then
  cp "$DEPLOY_DIR"/secrets/* "$app/secrets/"
fi

mkdir -p "$ROOT/dist/bundle"
out="$ROOT/dist/bundle/couple-ledger-$VERSION.tar.gz"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$out" -C "$stage" couple-ledger
echo ">> ${out}（$(du -h "$out" | cut -f1)）"
echo ">> 服务器地址：https://$HOST:$(grep -E '^LEDGER_PORT=' "$DEPLOY_DIR/.env" | cut -d= -f2-)"
