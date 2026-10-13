#!/usr/bin/env bash
# 一次性生成 App 签名材料（已存在的不会覆盖）：
#   - Android 正式版签名密钥（release.jks）
#   - 鸿蒙签名密钥（harmony.p12）和证书请求文件（harmony.csr）
#
# 全部放在 KEYS_DIR（默认 ~/.couple-ledger-keys），不进项目目录。
# 密码随机生成，保存在 KEYS_DIR/passwords.env。
# ⚠️ 请把整个目录备份到安全的地方：丢了 Android 密钥，以后升级就要先卸载旧版。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=dev-env.sh
source "$ROOT/tools/dev-env.sh"

KEYS_DIR=${KEYS_DIR:-$HOME/.couple-ledger-keys}
mkdir -p "$KEYS_DIR/harmony"
chmod 700 "$KEYS_DIR"

PASS_FILE="$KEYS_DIR/passwords.env"
if [[ ! -f $PASS_FILE ]]; then
  gen() { openssl rand -base64 18 | tr -d '/+=' | cut -c1-20; }
  cat > "$PASS_FILE" <<EOF
ANDROID_STORE_PASSWORD=$(gen)
HARMONY_STORE_PASSWORD=$(gen)
EOF
  chmod 600 "$PASS_FILE"
fi
# shellcheck disable=SC1090
source "$PASS_FILE"

if [[ ! -f $KEYS_DIR/release.jks ]]; then
  echo ">> 生成 Android 签名密钥"
  keytool -genkeypair -v -keystore "$KEYS_DIR/release.jks" -alias couple-ledger \
    -keyalg RSA -keysize 2048 -validity 36500 \
    -storepass "$ANDROID_STORE_PASSWORD" -keypass "$ANDROID_STORE_PASSWORD" \
    -dname "CN=Couple Ledger, O=CoupleLedger, C=CN" >/dev/null
fi

SIGN_TOOL="$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar"
if [[ ! -f $KEYS_DIR/harmony/harmony.p12 ]]; then
  echo ">> 生成鸿蒙签名密钥"
  java -jar "$SIGN_TOOL" generate-keypair -keyAlias couple-ledger -keyAlg ECC -keySize NIST-P-256 \
    -keystoreFile "$KEYS_DIR/harmony/harmony.p12" \
    -keyPwd "$HARMONY_STORE_PASSWORD" -keystorePwd "$HARMONY_STORE_PASSWORD"
fi
if [[ ! -f $KEYS_DIR/harmony/harmony.csr ]]; then
  java -jar "$SIGN_TOOL" generate-csr -keyAlias couple-ledger -keyPwd "$HARMONY_STORE_PASSWORD" \
    -subject "C=CN,O=CoupleLedger,OU=App,CN=couple-ledger" -signAlg SHA256withECDSA \
    -keystoreFile "$KEYS_DIR/harmony/harmony.p12" -keystorePwd "$HARMONY_STORE_PASSWORD" \
    -outFile "$KEYS_DIR/harmony/harmony.csr"
fi

echo
echo ">> 签名材料在 ${KEYS_DIR}："
ls -l "$KEYS_DIR" "$KEYS_DIR/harmony"
echo
echo "下一步（鸿蒙）：把 $KEYS_DIR/harmony/harmony.csr 上传到 AppGallery Connect 申请调试证书，"
echo "下载的 .cer 存成 $KEYS_DIR/harmony/debug.cer，调试 Profile 存成 $KEYS_DIR/harmony/debug.p7b。"
echo "详细步骤见 docs/鸿蒙签名与推送.md"
