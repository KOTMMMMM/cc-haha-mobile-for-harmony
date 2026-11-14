#!/usr/bin/env bash
# 一键构建 + 签名 + 安装（Git Bash / Linux / macOS 可用）
# 用法：
#   KEY_PWD='xxx' STORE_PWD='xxx' tools/build-sign-install.sh
# 可选环境变量：
#   DEVECO_HOME   默认 C:/Program Files/Huawei/DevEco Studio
#   KEY_ALIAS     keystore 别名（默认 cchaha_debug）
#   SIGNING_DIR   签名材料目录（默认仓库 signing/，否则 ~/.cc-haha-signing）
#   KEYSTORE / CERT / PROFILE  签名材料路径
#   COMPAT_VERSION  与 build-profile 的 compatibleSdkVersion 匹配（默认 23）
#   SKIP_INSTALL=1  只构建和签名，不安装
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/harmony-app"
DEVECO_HOME="${DEVECO_HOME:-C:/Program Files/Huawei/DevEco Studio}"
NODE_HOME="${NODE_HOME:-$DEVECO_HOME/tools/node}"
JAVA_HOME="${JAVA_HOME:-$DEVECO_HOME/jbr}"
export JAVA_HOME
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"
export PATH="$NODE_HOME:$JAVA_HOME/bin:$PATH"

HVIGOR="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
SIGN_TOOL="$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar"
HDC="${HDC:-$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc.exe}"

KEY_ALIAS="${KEY_ALIAS:-cchaha_debug}"
# 签名材料优先使用仓库内 signing/（兼容旧布局），否则回退到用户目录
SIGNING_DIR="${SIGNING_DIR:-$ROOT/signing}"
if [ ! -d "$SIGNING_DIR" ] && [ -d "$HOME/.cc-haha-signing" ]; then
  SIGNING_DIR="$HOME/.cc-haha-signing"
fi
CERT="${CERT:-$SIGNING_DIR/cchaha_debug.cer}"
PROFILE="${PROFILE:-$SIGNING_DIR/cchaha_debug_profile.p7b}"
KEYSTORE="${KEYSTORE:-$SIGNING_DIR/cchaha_debug.p12}"
COMPAT_VERSION="${COMPAT_VERSION:-23}"

for f in "$KEYSTORE" "$CERT" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    echo "错误：找不到签名材料 $f" >&2
    exit 1
  fi
done

KEY_PWD="${KEY_PWD:-${HAP_KEY_PWD:-}}"
STORE_PWD="${STORE_PWD:-${HAP_STORE_PWD:-$KEY_PWD}}"
if [ -z "$KEY_PWD" ]; then
  echo "错误：请通过 KEY_PWD（和可选 STORE_PWD）传入签名密码，不要把密码写进仓库。" >&2
  exit 1
fi

cd "$APP"
echo "==> 校验预编译库"
if [ -f "entry/libs/arm64-v8a/SHA256SUMS" ]; then
  ( cd entry/libs/arm64-v8a && sha256sum -c SHA256SUMS )
else
  echo "警告：缺少 entry/libs/arm64-v8a/SHA256SUMS，跳过校验" >&2
fi

echo "==> 构建 HAP"
node "$HVIGOR" assembleHap --no-daemon

OUT_DIR="$APP/entry/build/default/outputs/default"
UNSIGNED="$OUT_DIR/entry-default-unsigned.hap"
SIGNED="$OUT_DIR/entry-default-signed.hap"
if [ ! -f "$UNSIGNED" ]; then
  echo "错误：没有找到 $UNSIGNED" >&2
  exit 1
fi

echo "==> 签名 HAP"
"$JAVA_HOME/bin/java.exe" -jar "$SIGN_TOOL" sign-app -mode localSign \
  -keyAlias "$KEY_ALIAS" -keyPwd "$KEY_PWD" \
  -appCertFile "$CERT" -profileFile "$PROFILE" \
  -inFile "$UNSIGNED" -signAlg SHA256withECDSA \
  -keystoreFile "$KEYSTORE" -keystorePwd "$STORE_PWD" \
  -outFile "$SIGNED" -compatibleVersion "$COMPAT_VERSION" -pwdInputMode 0

echo "==> 产物：$SIGNED"

if [ "${SKIP_INSTALL:-0}" != "1" ]; then
  echo "==> 安装到设备"
  # Git Bash 下 hdc 不识别 /c/... 形式的 POSIX 路径，进入产物目录用相对名
  ( cd "$OUT_DIR" && "$HDC" install -r "entry-default-signed.hap" )
fi
