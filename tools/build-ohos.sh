#!/usr/bin/env bash
# 构建并签名鸿蒙安装包（HAP），产物在 dist/ohos/。
#
# 鸿蒙的 hvigor 不接受包含中文的项目路径，所以先把 app/ 同步到一个纯英文路径的
# 镜像目录里构建；构建出未签名的 HAP 后，用 SDK 自带的 hap-sign-tool 签名。
#
# 用法：tools/build-ohos.sh                # 正式构建（release 模式，调试证书签名）
#       tools/build-ohos.sh --debug        # debug 模式
#       tools/build-ohos.sh --install      # 构建后用 hdc 安装到连着的手机
#       tools/build-ohos.sh --public       # 公开版：不含自己服务器的地址、证书和华为应用 ID，
#                                          # 没有自己的服务器时用它（可和 --install 一起用）；
#                                          # 两人同步默认用 tools/relay/ 里作者的服务器转发，RELAY_URL= 可关闭
#       tools/build-ohos.sh --store        # 上架华为应用市场：公开版，打 .app 包，用发布证书和发布 Profile
#                                          #（~/.couple-ledger-keys/harmony/release.cer、release.p7b）签名
# 签名材料见 tools/setup-signing.sh 与 docs/鸿蒙签名与推送.md
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEYS_DIR=${KEYS_DIR:-$HOME/.couple-ledger-keys}

MODE=--release
INSTALL=false
PUBLIC=false
STORE=false
for arg in "$@"; do
  case $arg in
    --debug) MODE=--debug ;;
    --install) INSTALL=true ;;
    --public) PUBLIC=true ;;
    --store) STORE=true; PUBLIC=true; MODE=--release ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

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
install_ca "$MIRROR/app/assets/ca.crt"
install_relay_ca "$MIRROR/app/assets/relay_ca.crt"

# Push Kit client id (AppGallery Connect → 项目设置 → 应用 → Client ID)
if [[ $PUBLIC == true ]]; then
  : # push needs the AppGallery app of whoever signs the build
elif [[ -n ${HUAWEI_APP_CLIENT_ID:-} ]]; then
  sed -i '' "s/REPLACE_WITH_AGC_CLIENT_ID/$HUAWEI_APP_CLIENT_ID/" "$MIRROR/app/ohos/entry/src/main/module.json5"
elif [[ -f $KEYS_DIR/harmony/client_id.txt ]]; then
  sed -i '' "s/REPLACE_WITH_AGC_CLIENT_ID/$(tr -d '[:space:]' < "$KEYS_DIR/harmony/client_id.txt")/" "$MIRROR/app/ohos/entry/src/main/module.json5"
else
  echo "⚠️  没有配置 Push Kit Client ID（$KEYS_DIR/harmony/client_id.txt），鸿蒙后台推送不会生效" >&2
fi

cd "$MIRROR/app"
mkdir -p "$ROOT/dist/ohos"
version=$(grep -E '^version:' "$ROOT/app/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)
sign_tool="$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar"

if $STORE; then
  cert="$KEYS_DIR/harmony/release.cer"
  profile="$KEYS_DIR/harmony/release.p7b"
  [[ -f $cert && -f $profile ]] || { echo "缺少发布证书 $cert 或发布 Profile ${profile}，见 docs/鸿蒙签名与推送.md" >&2; exit 1; }
  # shellcheck disable=SC1091
  source "$KEYS_DIR/passwords.env"
  release_sign() { # <in> <out> <signCode>
    java -jar "$sign_tool" sign-app \
      -mode localSign -signAlg SHA256withECDSA -keyAlias couple-ledger \
      -keyPwd "$HARMONY_STORE_PASSWORD" -keystoreFile "$KEYS_DIR/harmony/harmony.p12" -keystorePwd "$HARMONY_STORE_PASSWORD" \
      -appCertFile "$cert" -profileFile "$profile" -profileSigned 1 -inForm zip -signCode "$3" \
      -inFile "$1" -outFile "$2"
  }
  app_unsigned="$MIRROR/app/ohos/build/outputs/default/ohos-default-unsigned.app"
  rm -f "$app_unsigned"
  # like the HAP build below: exits non-zero without an IDE signing config
  flutter build app --release --dart-define=LEDGER_SERVER= --dart-define=LEDGER_RELAY="$RELAY_URL" || true
  [[ -f $app_unsigned ]] || { echo "构建失败：没有生成 .app" >&2; exit 1; }

  # sign every HAP inside, repack, then sign the .app itself
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  (cd "$work" && unzip -q "$app_unsigned")
  for hap in "$work"/*.hap; do
    release_sign "$hap" "$hap.signed" 1
    mv "$hap.signed" "$hap"
  done
  (cd "$work" && zip -q -X -0 repacked.app pack.info pac.json && zip -q -X -9 repacked.app ./*.hap)
  store_app="$ROOT/dist/ohos/liangrenzhang-${version}-appgallery.app"
  release_sign "$work/repacked.app" "$store_app" 0
  java -jar "$sign_tool" verify-app -inFile "$store_app" -inForm zip \
    -outCertChain "$work/chain.cer" -outProfile "$work/profile.p7b" >/dev/null
  echo ">> $store_app"
  echo ">> 上架包：公开版，两人同步转发：${RELAY_URL:-（不提供）}；在 AppGallery Connect 的版本信息里上传"
  exit 0
fi

unsigned="$MIRROR/app/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap"
rm -f "$unsigned"
# the flutter tool exits non-zero when the project has no IDE signing config,
# even though hvigor produced the unsigned HAP; we sign it ourselves below
flutter build hap "$MODE" --dart-define=LEDGER_SERVER="$SERVER_URL" --dart-define=LEDGER_RELAY="$RELAY_URL" || true
[[ -f $unsigned ]] || { echo "构建失败：没有生成 HAP" >&2; exit 1; }

kind=${MODE#--}
if [[ $PUBLIC == true ]]; then kind=public; fi

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
java -jar "$sign_tool" sign-app \
  -mode localSign -signAlg SHA256withECDSA -keyAlias couple-ledger \
  -keyPwd "$HARMONY_STORE_PASSWORD" -keystoreFile "$KEYS_DIR/harmony/harmony.p12" -keystorePwd "$HARMONY_STORE_PASSWORD" \
  -appCertFile "$cert" -profileFile "$profile" -profileSigned 1 -inForm zip -signCode 1 \
  -inFile "$unsigned" -outFile "$signed"
echo ">> $signed"
if [[ $PUBLIC == true ]]; then
  echo ">> 公开版：不含自己服务器的地址和证书"
  echo ">> 两人同步转发：${RELAY_URL:-（不提供）}"
else
  echo ">> 服务器地址：$SERVER_URL"
fi

if $INSTALL; then
  hdc install -r "$signed"
fi
