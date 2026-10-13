#!/usr/bin/env bash
# 整体打包数据目录（服务器上由 cron 每天执行，也可以手动运行）。
#
# 为保证 SQLite 数据一致，打包时会短暂停止 pocketbase 容器（通常 1~3 秒），
# Caddy 不受影响。PocketBase 自带的每日备份（data/pb_data/backups）也同时开启。
#
# 用法：backup.sh [保留份数，默认 14]
set -euo pipefail

KEEP=${1:-14}
cd "$(dirname "$0")"
mkdir -p backups

stamp=$(date +%Y%m%d-%H%M%S)
out="backups/ledger-$stamp.tar.gz"

docker compose stop pocketbase
trap 'docker compose start pocketbase' EXIT
tar czf "$out" data/pb_data data/certs .env docker-compose.yml Caddyfile secrets
docker compose start pocketbase
trap - EXIT

chmod 600 "$out"
echo "$(date '+%F %T') 备份完成：$out ($(du -h "$out" | cut -f1))"

ls -1t backups/ledger-*.tar.gz | tail -n +"$((KEEP + 1))" | xargs -r rm -f
