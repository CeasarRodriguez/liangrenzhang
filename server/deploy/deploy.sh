#!/usr/bin/env bash
# 把指定版本部署到服务器（在 Mac 上运行）。
#
# 用法：deploy.sh <ssh目标> <版本号> [平台]
#   例：./deploy.sh root@1.2.3.4 1.0.0 linux/amd64
#
# 前置条件：
#   1. 服务器已运行过 install-docker.sh
#   2. 已执行 build-image.sh 生成镜像 tar
#   3. deploy/.env 已按 .env.example 填好
#   4. 已用 gen-certs.sh 为服务器 IP 生成证书到 deploy/data/certs/
set -euo pipefail

TARGET=${1:?用法: deploy.sh <ssh目标> <版本号> [平台]}
VERSION=${2:?用法: deploy.sh <ssh目标> <版本号> [平台]}
PLATFORM=${3:-linux/amd64}
ARCH=${PLATFORM#linux/}
REMOTE_DIR=${REMOTE_DIR:-/opt/couple-ledger}

DEPLOY_DIR=$(cd "$(dirname "$0")" && pwd)
IMAGES_DIR=$(dirname "$(dirname "$DEPLOY_DIR")")/dist/images

[[ -f $DEPLOY_DIR/.env ]] || { echo "缺少 deploy/.env，请先复制 .env.example 并填写" >&2; exit 1; }
[[ -f $DEPLOY_DIR/data/certs/server.crt ]] || { echo "缺少证书，请先运行 gen-certs.sh" >&2; exit 1; }

CADDY_IMAGE=$(grep -E '^CADDY_IMAGE=' "$DEPLOY_DIR/.env" | cut -d= -f2-)
server_tar="$IMAGES_DIR/couple-ledger-server_${VERSION}_${ARCH}.tar.gz"
caddy_tar="$IMAGES_DIR/$(echo "$CADDY_IMAGE" | tr ':/' '__')_${ARCH}.tar.gz"
for f in "$server_tar" "$caddy_tar"; do
  [[ -f $f ]] || { echo "找不到镜像文件 ${f}，请先运行 build-image.sh $VERSION $PLATFORM" >&2; exit 1; }
done

# keep the version in .env in sync with what we deploy
sed -i.bak "s/^LEDGER_VERSION=.*/LEDGER_VERSION=$VERSION/" "$DEPLOY_DIR/.env" && rm -f "$DEPLOY_DIR/.env.bak"

echo ">> 上传文件到 $TARGET:$REMOTE_DIR"
ssh "$TARGET" "mkdir -p $REMOTE_DIR/images $REMOTE_DIR/data/pb_data $REMOTE_DIR/data/relay $REMOTE_DIR/data/caddy $REMOTE_DIR/data/certs $REMOTE_DIR/secrets $REMOTE_DIR/backups"
scp "$server_tar" "$caddy_tar" "$TARGET:$REMOTE_DIR/images/"
scp "$DEPLOY_DIR/docker-compose.yml" "$DEPLOY_DIR/Caddyfile" "$DEPLOY_DIR/.env" \
    "$DEPLOY_DIR/backup.sh" "$TARGET:$REMOTE_DIR/"
scp "$DEPLOY_DIR/data/certs/server.crt" "$DEPLOY_DIR/data/certs/server.key" "$DEPLOY_DIR/data/certs/ca.crt" \
    "$TARGET:$REMOTE_DIR/data/certs/"
if compgen -G "$DEPLOY_DIR/secrets/*" > /dev/null; then
  scp "$DEPLOY_DIR"/secrets/* "$TARGET:$REMOTE_DIR/secrets/"
fi

echo ">> 加载镜像并启动"
ssh "$TARGET" bash -s -- "$REMOTE_DIR" "$(basename "$server_tar")" "$(basename "$caddy_tar")" <<'REMOTE'
set -euo pipefail
cd "$1"
gunzip -c "images/$2" | docker load
gunzip -c "images/$3" | docker load
chown -R 10001:10001 data/pb_data data/relay
chmod 600 .env
chmod +x backup.sh
docker compose up -d
# daily backup at 04:15 (idempotent crontab entry)
{ crontab -l 2>/dev/null | grep -v 'couple-ledger/backup.sh' || true
  echo "15 4 * * * $PWD/backup.sh >> $PWD/backups/backup.log 2>&1"; } | crontab -

for i in $(seq 1 30); do
  status=$(docker inspect -f '{{.State.Health.Status}}' couple-ledger-pocketbase-1 2>/dev/null || echo starting)
  [[ $status == healthy ]] && break
  sleep 2
done
docker compose ps
port=$(grep -E '^LEDGER_PORT=' .env | cut -d= -f2-)
curl -fsS --cacert data/certs/ca.crt --resolve "$(grep -E '^LEDGER_HOST=' .env | cut -d= -f2-):${port:-8443}:127.0.0.1" \
  "https://$(grep -E '^LEDGER_HOST=' .env | cut -d= -f2-):${port:-8443}/api/health" && echo && echo ">> 部署成功"
REMOTE

echo ">> 证书指纹（App 第一次连接时会让你核对）："
openssl x509 -noout -fingerprint -sha256 -in "$DEPLOY_DIR/data/certs/server.crt"
