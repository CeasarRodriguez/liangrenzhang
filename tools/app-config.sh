# Shared by build-android.sh / build-ohos.sh: works out the server URL and
# installs our root CA into the app assets. The public build (PUBLIC=true)
# bakes in neither: its users pick offline trial or their own server.

CA_FILE=${CA_FILE:-$HOME/.couple-ledger-ca/ca.crt}

if [[ ${PUBLIC:-false} == true ]]; then
  SERVER_URL=""
elif [[ -z ${SERVER_URL:-} ]]; then
  env_file="$ROOT/server/deploy/.env"
  if [[ -f $env_file ]]; then
    host=$(grep -E '^LEDGER_HOST=' "$env_file" | cut -d= -f2-)
    port=$(grep -E '^LEDGER_PORT=' "$env_file" | cut -d= -f2-)
    SERVER_URL="https://${host}:${port:-8443}"
  else
    echo "找不到 server/deploy/.env，请先配置服务器，或用 SERVER_URL=https://IP:8443 指定" >&2
    exit 1
  fi
fi

install_ca() {
  if [[ ${PUBLIC:-false} == true ]]; then
    : > "$1"
  elif [[ -f $CA_FILE ]]; then
    cp "$CA_FILE" "$1"
  else
    echo "⚠️  没找到根证书 ${CA_FILE}，App 只信任系统证书（用 IP 访问服务器会连不上）" >&2
    : > "$1"
  fi
}
