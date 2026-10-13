#!/usr/bin/env bash
# 构建 Android 安装包（APK），产物在 dist/android/。
#
# 服务器地址取自 server/deploy/.env（LEDGER_HOST + LEDGER_PORT），
# 根证书取自 ~/.couple-ledger-ca/ca.crt，签名密钥见 tools/setup-signing.sh。
#
# 用法：tools/build-android.sh            # 正式版
#       tools/build-android.sh --debug    # 调试版
#       tools/build-android.sh --offline  # 单机体验版：不连服务器，数据只存在手机上
#       SERVER_URL=https://1.2.3.4:8443 tools/build-android.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

MODE=--release
OFFLINE=false
for arg in "$@"; do
  case $arg in
    --debug) MODE=--debug ;;
    --offline) OFFLINE=true ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done
# the trial build never contacts a server
if [[ $OFFLINE == true ]]; then SERVER_URL=${SERVER_URL:-https://127.0.0.1:8443}; fi

# shellcheck source=dev-env.sh
source "$ROOT/tools/dev-env.sh"
# shellcheck source=app-config.sh
source "$ROOT/tools/app-config.sh"
export FLUTTER_SUPPRESS_ANALYTICS=true

cd "$ROOT/app"
install_ca "$ROOT/app/assets/ca.crt"
trap ': > "$ROOT/app/assets/ca.crt"' EXIT

flutter build apk "$MODE" --target-platform android-arm64 \
  --dart-define=LEDGER_SERVER="$SERVER_URL" --dart-define=LEDGER_OFFLINE="$OFFLINE"

mkdir -p "$ROOT/dist/android"
kind=${MODE#--}
apk="build/app/outputs/flutter-apk/app-${kind}.apk"
if [[ $OFFLINE == true ]]; then kind=offline; fi
version=$(grep -E '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
out="$ROOT/dist/android/liangrenzhang-${version}-${kind}.apk"
cp "$apk" "$out"
echo ">> $out"
if [[ $OFFLINE == true ]]; then
  echo ">> 单机体验版，不连服务器"
else
  echo ">> 服务器地址：$SERVER_URL"
fi
