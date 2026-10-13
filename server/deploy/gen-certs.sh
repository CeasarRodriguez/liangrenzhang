#!/usr/bin/env bash
# 生成自建根证书（只生成一次）并签发服务器证书。
#
# 用法：gen-certs.sh <输出目录> <服务器IP或域名> [更多IP/域名...]
#   例：./gen-certs.sh ./data/certs 1.2.3.4
#
# - 根证书放在 CA_DIR（默认 ~/.couple-ledger-ca），私钥只留在你自己的电脑上，
#   App 内置的是 ca.crt（公钥证书）。迁移服务器时用同一个根证书重新签发即可，
#   App 不需要重新打包。
# - 输出目录会得到 server.crt / server.key，以及一份 ca.crt 副本。
set -euo pipefail

OUT_DIR=${1:?用法: gen-certs.sh <输出目录> <服务器IP或域名>...}
shift
[[ $# -ge 1 ]] || { echo "至少需要一个服务器 IP 或域名" >&2; exit 1; }

CA_DIR=${CA_DIR:-$HOME/.couple-ledger-ca}
DAYS=${DAYS:-3650}

mkdir -p "$CA_DIR" "$OUT_DIR"
chmod 700 "$CA_DIR"

if [[ ! -f "$CA_DIR/ca.key" ]]; then
  echo ">> 生成根证书：$CA_DIR"
  openssl ecparam -name prime256v1 -genkey -noout -out "$CA_DIR/ca.key"
  chmod 600 "$CA_DIR/ca.key"
  openssl req -x509 -new -key "$CA_DIR/ca.key" -sha256 -days 7300 \
    -subj "/CN=Couple Ledger Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$CA_DIR/ca.crt"
else
  echo ">> 使用已有根证书：$CA_DIR/ca.crt"
fi

san=""
for host in "$@"; do
  if [[ $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || $host == *:* ]]; then
    san+="IP:$host,"
  else
    san+="DNS:$host,"
  fi
done
san=${san%,}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/server.key"
openssl req -new -key "$tmp/server.key" -subj "/CN=$1" -out "$tmp/server.csr"
cat > "$tmp/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$san
EOF
openssl x509 -req -in "$tmp/server.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
  -CAcreateserial -CAserial "$CA_DIR/ca.srl" -days "$DAYS" -sha256 \
  -extfile "$tmp/ext.cnf" -out "$tmp/server.crt"

install -m 644 "$tmp/server.crt" "$OUT_DIR/server.crt"
# Caddy runs as root inside its container, but keep the key unreadable for others on the host
install -m 640 "$tmp/server.key" "$OUT_DIR/server.key"
install -m 644 "$CA_DIR/ca.crt" "$OUT_DIR/ca.crt"

echo ">> 已签发服务器证书（${san}），有效期 $DAYS 天：$OUT_DIR/server.crt"
openssl x509 -in "$OUT_DIR/server.crt" -noout -subject -enddate
