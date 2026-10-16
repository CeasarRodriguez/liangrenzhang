# Shared by build-android.sh / build-ohos.sh: works out the server URL and
# installs our root CA into the app assets. The public build (PUBLIC=true)
# bakes in neither: its users pick offline trial, relay mode or their own
# server. Relay mode uses RELAY_URL (default: the server in
# server/deploy/.env) and trusts RELAY_CA_FILE for that connection only;
# RELAY_URL= (empty) builds without relay mode.

CA_FILE=${CA_FILE:-$HOME/.couple-ledger-ca/ca.crt}
RELAY_CA_FILE=${RELAY_CA_FILE:-$CA_FILE}

server_from_env() {
  local env_file="$ROOT/server/deploy/.env" host port
  [[ -f $env_file ]] || return 1
  host=$(grep -E '^LEDGER_HOST=' "$env_file" | cut -d= -f2-)
  port=$(grep -E '^LEDGER_PORT=' "$env_file" | cut -d= -f2-)
  echo "https://${host}:${port:-8443}"
}

if [[ ${PUBLIC:-false} == true ]]; then
  SERVER_URL=""
  if [[ -z ${RELAY_URL+set} ]]; then
    RELAY_URL=$(server_from_env) || {
      RELAY_URL=""
      echo "⚠️  找不到 server/deploy/.env，公开版不提供「两人同步」（可用 RELAY_URL=https://IP:8443 指定）" >&2
    }
  fi
else
  RELAY_URL=""
  if [[ -z ${SERVER_URL:-} ]]; then
    SERVER_URL=$(server_from_env) || {
      echo "找不到 server/deploy/.env，请先配置服务器，或用 SERVER_URL=https://IP:8443 指定" >&2
      exit 1
    }
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

# root CA of the relay server, trusted for relay connections only
install_relay_ca() {
  if [[ -z ${RELAY_URL:-} ]]; then
    : > "$1"
  elif [[ -f $RELAY_CA_FILE ]]; then
    cp "$RELAY_CA_FILE" "$1"
  else
    echo "⚠️  没找到转发服务器的根证书 ${RELAY_CA_FILE}，「两人同步」只信任系统证书" >&2
    : > "$1"
  fi
}
