#!/usr/bin/env bash
# 构建并签名鸿蒙安装包（HAP），产物在 dist/ohos/。
#
# 鸿蒙的 hvigor 不接受包含中文的项目路径，所以先把 app/ 同步到一个纯英文路径的
# 镜像目录里构建；构建出未签名的 HAP 后，用 SDK 自带的 hap-sign-tool 签名。
#
# 用法：tools/build-ohos.sh                # 正式构建（release 模式，调试证书签名）
#       tools/build-ohos.sh --debug        # debug 模式
#       tools/build-ohos.sh --install      # 构建后用 hdc 安装到连着的手机
#       tools/build-ohos.sh --offline      # 单机体验版：不连服务器，数据只存在手机上
# 签名材料见 tools/setup-signing.sh 与 docs/鸿蒙签名与推送.md
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEYS_DIR=${KEYS_DIR:-$HOME/.couple-ledger-keys}

MODE=--release
INSTALL=false
OFFLINE=false
for arg in "$@"; do
  case $arg in
    --debug) MODE=--debug ;;
    --install) INSTALL=true ;;
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
MIRROR=${OHOS_BUILD_MIRROR:-$DEVTOOLS/build/couple-ledger}

mkdir -p "$MIRROR"
# build outputs and package caches stay in the mirror between runs
rsync -a --delete \
  --exclude build/ --exclude .dart_tool/ \
  --exclude ohos/oh_modules/ --exclude ohos/.hvigor/ --exclude ohos/build/ \
  --exclude ohos/entry/build/ --exclude ohos/entry/oh_modules/ --exclude ohos/local.properties \
  --exclude ohos/oh-package-lock.json5 \
  "$ROOT/app/" "$MIRROR/app/"
rsync -a --delete "$ROOT/shared/" "$MIRROR/shared/"
if [[ $OFFLINE == true ]]; then : > "$MIRROR/app/assets/ca.crt"; else install_ca "$MIRROR/app/assets/ca.crt"; fi

# Push Kit client id (AppGallery Connect → 项目设置 → 应用 → Client ID)
if [[ $OFFLINE == true ]]; then
  : # the trial build has no push, so it carries no AppGallery id
elif [[ -n ${HUAWEI_APP_CLIENT_ID:-} ]]; then
  sed -i '' "s/REPLACE_WITH_AGC_CLIENT_ID/$HUAWEI_APP_CLIENT_ID/" "$MIRROR/app/ohos/entry/src/main/module.json5"
elif [[ -f $KEYS_DIR/harmony/client_id.txt ]]; then
  sed -i '' "s/REPLACE_WITH_AGC_CLIENT_ID/$(tr -d '[:space:]' < "$KEYS_DIR/harmony/client_id.txt")/" "$MIRROR/app/ohos/entry/src/main/module.json5"
else
  echo "⚠️  没有配置 Push Kit Client ID（$KEYS_DIR/harmony/client_id.txt），鸿蒙后台推送不会生效" >&2
fi

cd "$MIRROR/app"
unsigned="$MIRROR/app/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap"
rm -f "$unsigned"
# the flutter tool exits non-zero when the project has no IDE signing config,
# even though hvigor produced the unsigned HAP; we sign it ourselves below
flutter build hap "$MODE" --dart-define=LEDGER_SERVER="$SERVER_URL" --dart-define=LEDGER_OFFLINE="$OFFLINE" || true
[[ -f $unsigned ]] || { echo "构建失败：没有生成 HAP" >&2; exit 1; }

mkdir -p "$ROOT/dist/ohos"
kind=${MODE#--}
if [[ $OFFLINE == true ]]; then kind=offline; fi
version=$(grep -E '^version:' "$ROOT/app/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)

cert="$KEYS_DIR/harmony/debug.cer"
profile="$KEYS_DIR/harmony/debug.p7b"
if [[ ! -f $cert || ! -f $profile ]]; then
  cp "$unsigned" "$ROOT/dist/ohos/liangrenzhang-${version}-${kind}-unsigned.hap"
  echo "⚠️  还没有 $cert / ${profile}，只生成了未签名的 HAP（不能安装到手机）" >&2
  exit 0
fi

# shellcheck disable=SC1091
source "$KEYS_DIR/passwords.env"
signed="$ROOT/dist/ohos/liangrenzhang-${version}-${kind}.hap"
java -jar "$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar" sign-app \
  -mode localSign -signAlg SHA256withECDSA -keyAlias couple-ledger \
  -keyPwd "$HARMONY_STORE_PASSWORD" -keystoreFile "$KEYS_DIR/harmony/harmony.p12" -keystorePwd "$HARMONY_STORE_PASSWORD" \
  -appCertFile "$cert" -profileFile "$profile" -profileSigned 1 -inForm zip -signCode 1 \
  -inFile "$unsigned" -outFile "$signed"
echo ">> $signed"
if [[ $OFFLINE == true ]]; then
  echo ">> 单机体验版，不连服务器"
else
  echo ">> 服务器地址：$SERVER_URL"
fi

if $INSTALL; then
  hdc install -r "$signed"
fi
