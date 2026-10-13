# 开发环境变量。用法：
#   source tools/dev-env.sh
# 想每次打开终端都生效，可以把上面这行（写绝对路径）加到 ~/.zshrc。
#
# 工具链默认在 ~/DevTools。装在别处时，新建 tools/dev-env.local.sh（不进仓库）写上：
#   export DEVTOOLS=/你的/工具链/目录

_dev_env_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck disable=SC1091
[[ -f $_dev_env_dir/dev-env.local.sh ]] && source "$_dev_env_dir/dev-env.local.sh"
unset _dev_env_dir
export DEVTOOLS=${DEVTOOLS:-$HOME/DevTools}

export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=$DEVTOOLS/android-sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export ANDROID_AVD_HOME=$DEVTOOLS/android-avd

# caches on the external drive (the system disk is nearly full)
export PUB_CACHE=$DEVTOOLS/pub-cache
export GRADLE_USER_HOME=$DEVTOOLS/gradle
export GOPATH=$DEVTOOLS/go
export GOMODCACHE=$GOPATH/pkg/mod

# HarmonyOS command-line tools (ohpm, hvigorw, hdc, bundled node and SDK)
export TOOL_HOME=$DEVTOOLS/harmony-cli
export DEVECO_SDK_HOME=$TOOL_HOME/sdk
export HOS_SDK_HOME=$DEVECO_SDK_HOME
export HDC_HOME=$DEVECO_SDK_HOME/default/openharmony/toolchains
export NODE_HOME=$TOOL_HOME/tool/node

export PATH=$DEVTOOLS/flutter_ohos/bin:$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$TOOL_HOME/bin:$NODE_HOME/bin:$HDC_HOME:$GOPATH/bin:$PATH
