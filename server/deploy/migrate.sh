#!/usr/bin/env bash
# 把整套服务从旧服务器迁移到新服务器（在 Mac 上运行）。
#
# 用法：migrate.sh <旧服务器ssh> <新服务器ssh> <新服务器IP或域名>
#   例：./migrate.sh root@1.2.3.4 root@5.6.7.8 5.6.7.8
#
# 流程：
#   1. 旧服务器停服并整体打包（数据、配置、镜像 tar）
#   2. 传到新服务器并解包、加载镜像
#   3. 用同一个根证书给新 IP 签发服务器证书（App 不用重新打包）
#   4. 启动并做健康检查
# 旧服务器只停不删，确认无误后再自行清理；出问题可在旧服务器 docker compose up -d 回滚。
# 新服务器需要先运行过 install-docker.sh。
set -euo pipefail

OLD=${1:?用法: migrate.sh <旧服务器ssh> <新服务器ssh> <新IP或域名>}
NEW=${2:?用法: migrate.sh <旧服务器ssh> <新服务器ssh> <新IP或域名>}
NEW_HOST=${3:?用法: migrate.sh <旧服务器ssh> <新服务器ssh> <新IP或域名>}
REMOTE_DIR=${REMOTE_DIR:-/opt/couple-ledger}

DEPLOY_DIR=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo ">> [1/4] 旧服务器停服并打包"
ssh "$OLD" "cd $REMOTE_DIR && docker compose down && tar czf /tmp/couple-ledger-migrate.tar.gz --exclude=./backups ."
scp "$OLD:/tmp/couple-ledger-migrate.tar.gz" "$work/bundle.tar.gz"
ssh "$OLD" "rm -f /tmp/couple-ledger-migrate.tar.gz"

echo ">> [2/4] 上传到新服务器"
ssh "$NEW" "mkdir -p $REMOTE_DIR"
scp "$work/bundle.tar.gz" "$NEW:/tmp/couple-ledger-migrate.tar.gz"
ssh "$NEW" "cd $REMOTE_DIR && tar xzf /tmp/couple-ledger-migrate.tar.gz && rm -f /tmp/couple-ledger-migrate.tar.gz && mkdir -p backups"

echo ">> [3/4] 为 $NEW_HOST 签发新证书"
"$DEPLOY_DIR/gen-certs.sh" "$work/certs" "$NEW_HOST"
scp "$work/certs/server.crt" "$work/certs/server.key" "$work/certs/ca.crt" "$NEW:$REMOTE_DIR/data/certs/"

echo ">> [4/4] 加载镜像并启动"
ssh "$NEW" bash -s -- "$REMOTE_DIR" "$NEW_HOST" <<'REMOTE'
set -euo pipefail
cd "$1"
sed -i "s/^LEDGER_HOST=.*/LEDGER_HOST=$2/" .env
version=$(grep -E '^LEDGER_VERSION=' .env | cut -d= -f2-)
caddy=$(grep -E '^CADDY_IMAGE=' .env | cut -d= -f2-)
docker image inspect "couple-ledger-server:$version" >/dev/null 2>&1 || gunzip -c images/couple-ledger-server_"${version}"_*.tar.gz | docker load
docker image inspect "$caddy" >/dev/null 2>&1 || gunzip -c images/"$(echo "$caddy" | tr ':/' '__')"_*.tar.gz | docker load
mkdir -p data/relay
chown -R 10001:10001 data/pb_data data/relay
docker compose up -d
( crontab -l 2>/dev/null | grep -v 'couple-ledger/backup.sh' ; echo "15 4 * * * $PWD/backup.sh >> $PWD/backups/backup.log 2>&1" ) | crontab -
for i in $(seq 1 30); do
  [[ $(docker inspect -f '{{.State.Health.Status}}' couple-ledger-pocketbase-1 2>/dev/null) == healthy ]] && break
  sleep 2
done
port=$(grep -E '^LEDGER_PORT=' .env | cut -d= -f2-)
curl -fsS --cacert data/certs/ca.crt --resolve "$2:${port:-8443}:127.0.0.1" "https://$2:${port:-8443}/api/health"
echo
REMOTE

# keep the local .env in sync
if [[ -f $DEPLOY_DIR/.env ]]; then
  sed -i.bak "s/^LEDGER_HOST=.*/LEDGER_HOST=$NEW_HOST/" "$DEPLOY_DIR/.env" && rm -f "$DEPLOY_DIR/.env.bak"
fi

port=$(grep -E '^LEDGER_PORT=' "$DEPLOY_DIR/.env" 2>/dev/null | cut -d= -f2-)
echo
echo ">> 迁移完成。请在两台手机的 App「设置 → 服务器地址」改为：https://$NEW_HOST:${port:-8443}"
echo ">> 旧服务器 $OLD 已停服但数据仍保留，确认新服务器正常后再清理。"
