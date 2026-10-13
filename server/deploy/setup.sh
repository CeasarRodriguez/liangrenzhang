#!/usr/bin/env bash
# 在服务器上安装 / 升级两人账服务端（make-bundle.sh 打出的安装包里自带本脚本）。
#
# 用法（root）：
#   tar xzf couple-ledger-<版本>.tar.gz -C /opt
#   bash /opt/couple-ledger/setup.sh
#
# 重复执行是安全的：数据在 data/pb_data，升级时不会被覆盖。
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "请用 root 运行（sudo bash setup.sh）" >&2; exit 1; }
cd "$(dirname "$0")"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo ">> 安装 Docker"
  bash ./install-docker.sh
fi

echo ">> 加载镜像"
for f in images/*.tar.gz; do
  gunzip -c "$f" | docker load
done

mkdir -p data/pb_data data/caddy secrets backups
chown -R 10001:10001 data/pb_data
chmod 600 .env data/certs/server.key
chmod +x backup.sh

echo ">> 启动服务"
docker compose up -d --remove-orphans
# daily backup at 04:15 (idempotent crontab entry)
command -v crontab >/dev/null 2>&1 || apt-get install -y cron || true
if command -v crontab >/dev/null 2>&1; then
  # (crontab -l fails when there is no crontab yet, and grep -v fails on empty input)
  { crontab -l 2>/dev/null | grep -v 'couple-ledger/backup.sh' || true
    echo "15 4 * * * $PWD/backup.sh >> $PWD/backups/backup.log 2>&1"; } | crontab -
else
  echo "!! 没装上 cron，每日整包备份没有启用（PocketBase 自带的每日备份不受影响）" >&2
fi

for _ in $(seq 1 30); do
  status=$(docker inspect -f '{{.State.Health.Status}}' couple-ledger-pocketbase-1 2>/dev/null || echo starting)
  [[ $status == healthy ]] && break
  sleep 2
done
docker compose ps

host=$(grep -E '^LEDGER_HOST=' .env | cut -d= -f2-)
port=$(grep -E '^LEDGER_PORT=' .env | cut -d= -f2-)
port=${port:-8443}
if curl -fsS --cacert data/certs/ca.crt --resolve "$host:$port:127.0.0.1" "https://$host:$port/api/health"; then
  echo
  echo ">> 部署成功：https://$host:$port"
  echo ">> 证书指纹（App 第一次连接时会让你核对）："
  openssl x509 -noout -fingerprint -sha256 -in data/certs/server.crt 2>/dev/null || true
  echo ">> 别忘了在云厂商安全组放行 TCP $port"
else
  echo
  echo "!! 服务没有正常响应，最近的日志如下：" >&2
  docker compose logs --tail=50
  exit 1
fi
