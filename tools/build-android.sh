#!/usr/bin/env bash
# 构建 Android 安装包（APK），产物在 dist/android/。
#
# 服务器地址取自 server/deploy/.env（LEDGER_HOST + LEDGER_PORT），
# 根证书取自 ~/.couple-ledger-ca/ca.crt，签名密钥见 tools/setup-signing.sh。
#
# 用法：tools/build-android.sh            # 正式版（连自己的服务器）
#       tools/build-android.sh --debug    # 调试版
#       tools/build-android.sh --public   # 公开版：不含服务器地址和证书，首次打开选单机体验、两人同步或填服务器
#                                         # （两人同步默认用 tools/relay/ 里作者的服务器转发，RELAY_URL= 可关闭）
#       SERVER_URL=https://1.2.3.4:8443 tools/build-android.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

MODE=--release
PUBLIC=false
for arg in "$@"; do
  case $arg in
    --debug) MODE=--debug ;;
    --public) PUBLIC=true ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

# shellcheck source=dev-env.sh
source "$ROOT/tools/dev-env.sh"
# shellcheck source=app-config.sh
source "$ROOT/tools/app-config.sh"
export FLUTTER_SUPPRESS_ANALYTICS=true

cd "$ROOT/app"
install_ca "$ROOT/app/assets/ca.crt"
install_relay_ca "$ROOT/app/assets/relay_ca.crt"
trap ': > "$ROOT/app/assets/ca.crt"; : > "$ROOT/app/assets/relay_ca.crt"' EXIT

flutter build apk "$MODE" --target-platform android-arm64 \
  --dart-define=LEDGER_SERVER="$SERVER_URL" --dart-define=LEDGER_RELAY="$RELAY_URL"

mkdir -p "$ROOT/dist/android"
kind=${MODE#--}
apk="build/app/outputs/flutter-apk/app-${kind}.apk"
if [[ $PUBLIC == true ]]; then kind=public; fi
version=$(grep -E '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
out="$ROOT/dist/android/liangrenzhang-${version}-${kind}.apk"
cp "$apk" "$out"
echo ">> $out"
if [[ $PUBLIC == true ]]; then
  echo ">> 公开版：不含自己服务器的地址和证书"
  echo ">> 两人同步转发：${RELAY_URL:-（不提供）}"
else
  echo ">> 服务器地址：$SERVER_URL"
fi
