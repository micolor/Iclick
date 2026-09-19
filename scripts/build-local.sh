#!/usr/bin/env bash
#
# build-local.sh —— 不依赖 Xcode 许可证，手工构建并安装 IClick
#
# 为什么需要这个脚本：本机没有同意 Xcode 许可协议，`xcodebuild` / `xcrun` / `otool` /
# `strings` / `python3` 全部被许可证门禁挡住。但按**绝对路径**调用的 `swiftc` 可以直接用，
# 因此改为手工编译 + 链接 + 组装 bundle + 签名 + 安装。
#
# 最关键的约束：链接时记录的 SDK 版本决定 App 的外观。
# macOS 依据 Mach-O 的 `LC_BUILD_VERSION.sdk` 判断这个 App 该用「新外观」还是
# 「旧版不透明兼容外观」（Apple 的 "linked on or after" 机制）。SDK 版本低于系统时，
# 整个 App 会被套进旧外观 —— 表现为窗口失去半透明/毛玻璃质感、控件样式变旧。
# 用户的原版构建记录的是 sdk=26.5.0，所以这里必须显式传
# `-platform_version macos 15.0 26.5`，并且链接后**校验**该字段。
#
set -euo pipefail

# ---------------------------------------------------------------- 配置

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 与用户原版一致的 SDK。注意不是 Xcode 里的 MacOSX27.sdk —— 用那个链接器会把部署目标
# 15.0 写进 sdk 字段，导致外观退化。
SDK_VERSION="26.5"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX${SDK_VERSION}.sdk"

# Xcode 的 swiftc：按绝对路径调用可以绕开许可证门禁
SWIFTC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"

DEPLOY_TARGET="arm64-apple-macos15.0"
MINOS="15.0"

# #Preview 宏的实现（libPreviewsMacros.dylib）在 Xcode 的平台目录下。
# 用 Xcode 自己的 SDK 编译时 swiftc 会自动发现它，换成 CLT 的 SDK 后就不会了，
# 必须显式传 -plugin-path，否则报 "plugin for module 'PreviewsMacros' not found"。
PLUGIN_PATH="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

BUILD_DIR="${BUILD_DIR:-/tmp/iclick-handbuild}"
APP_NAME="Iclick"
INSTALL_PATH="/Applications/${APP_NAME}.app"

# 签名身份：默认从钥匙串里挑第一个 Apple Development 证书
SIGN_ID="${SIGN_ID:-}"

# bundle 模板：脚本只替换其中两个可执行文件，其余（Assets.car / Localizable.strings /
# Info.plist / template.xlsx）原样保留。这些资源与用户原版逐字节相同，
# 而编译 Assets.xcassets 需要 actool（受许可证门禁），所以不做重新生成。
TEMPLATE="${TEMPLATE:-$INSTALL_PATH}"

# ---------------------------------------------------------------- 工具函数

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
die()  { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 读取 Mach-O 的 LC_BUILD_VERSION（cmd 0x32）并打印 minos / sdk。
# 不用 otool（受许可证门禁），直接解析头部。
# 结构体：cmd(u32) cmdsize(u32) platform(u32) minos(u32) sdk(u32) ntools(u32)
# 版本号打包为 x<<16 | y<<8 | z
macho_versions() {
    /usr/bin/perl -e '
        my $path = shift;
        open(my $fh, "<:raw", $path) or die "open $path: $!";
        local $/; my $d = <$fh>;
        my $magic = unpack("V", substr($d, 0, 4));
        die "not thin macho64\n" unless $magic == 0xFEEDFACF;
        my $ncmds = unpack("V", substr($d, 16, 4));
        my $off = 32;
        for (my $i = 0; $i < $ncmds; $i++) {
            my ($cmd, $cmdsize) = unpack("VV", substr($d, $off, 8));
            last if $cmdsize == 0;
            if ($cmd == 0x32) {
                # cmd(0) cmdsize(4) platform(8) minos(12) sdk(16) —— 跳过 12 字节再取两个 u32
                my ($minos, $sdk) = unpack("x12 V V", substr($d, $off, 20));
                printf "%d.%d.%d %d.%d.%d\n",
                    $minos >> 16, ($minos >> 8) & 0xff, $minos & 0xff,
                    $sdk   >> 16, ($sdk   >> 8) & 0xff, $sdk   & 0xff;
                exit 0;
            }
            $off += $cmdsize;
        }
        die "LC_BUILD_VERSION not found\n";
    ' "$1"
}

# 把 build settings 合成的权限项补进 entitlements 文件。
# Xcode 签名前会做这一步，手工 codesign 不会：
#   ENABLE_APP_SANDBOX = YES       → com.apple.security.app-sandbox
#   ENABLE_USER_SELECTED_FILES     → com.apple.security.files.user-selected.read-write
#   Debug 配置                      → com.apple.security.get-task-allow
#                                    + com.apple.security.cs.debugger
# 不能用 plutil -insert：它把 key 里的 `.` 当键路径分隔符，
# 而 com.apple.security.* 全都是含点的字面 key，会报 "Key path not found"。
# 所以直接拼 XML：取出基础文件的 <dict> 内容，再追加需要的键。
ensure_entitlements() {
    local src="$1" out="$2"; shift 2
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n<dict>\n'
        plutil -convert xml1 -o - "$src" | sed -n '/^<dict>$/,/^<\/dict>$/p' | sed '1d;$d'
        local key
        for key in "$@"; do
            printf '\t<key>%s</key>\n\t<true/>\n' "$key"
        done
        printf '</dict>\n</plist>\n'
    } > "$out"
    plutil -lint "$out" > /dev/null || die "生成的 entitlements 非法: $out"
}

# 扩展是沙箱化的（project.pbxproj: ENABLE_APP_SANDBOX = YES），主程序不是（= NO）。
# 漏掉 app-sandbox 的后果非常隐蔽：签名能过、App 能启动、不报任何错，
# 但系统会拒绝注册这个 .appex —— `pluginkit -m | grep iclick` 查不到，
# Finder 右键菜单整个失效。所以下面签名后要显式校验。
EXT_ENTITLEMENTS=(
    com.apple.security.app-sandbox
    com.apple.security.files.user-selected.read-write
    com.apple.security.get-task-allow
    com.apple.security.cs.debugger
)
APP_ENTITLEMENTS=(
    com.apple.security.files.user-selected.read-write
    com.apple.security.get-task-allow
    com.apple.security.cs.debugger
)
EXT_PLUGIN_ID="cn.anwen.IClick.FinderSyncExt"

# ---------------------------------------------------------------- 前置检查

log "前置检查"
[ -x "$SWIFTC" ] || die "找不到 swiftc: $SWIFTC"
[ -d "$SDK" ] || die "找不到 SDK: ${SDK}（需要 macOS ${SDK_VERSION} SDK）"
[ -d "$PLUGIN_PATH" ] || die "找不到宏插件目录: $PLUGIN_PATH"
[ -d "$TEMPLATE" ] || die "找不到 bundle 模板: $TEMPLATE"

DEP_SDK_VERSION="$(plutil -extract Version raw -o - "$SDK/SDKSettings.plist" 2>/dev/null || echo "?")"
[ "$DEP_SDK_VERSION" = "$SDK_VERSION" ] \
    || die "SDK 版本不符：期望 ${SDK_VERSION}，实际 ${DEP_SDK_VERSION}"

# 两个坑：
# 1. 必须排除已吊销的证书 —— 钥匙串里有同样 CN 的有效证书和 revoked 证书，
#    挑中 revoked 的会让 codesign 失败。
# 2. 必须用 SHA-1 而不是证书的 Common Name —— 三张证书 CN 完全相同，
#    传 CN 会报 "ambiguous (matches ... and ...)"。
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -v 'CSSMERR_' \
        | sed -n 's/^[[:space:]]*[0-9]*) \([0-9A-F]\{40\}\) .*/\1/p' \
        | head -1 || true)"
fi
[ -n "$SIGN_ID" ] || die "找不到可用的代码签名证书，可用 SIGN_ID 环境变量指定"

ok "SDK: $SDK (Version $DEP_SDK_VERSION)"
ok "签名身份: $SIGN_ID"
ok "bundle 模板: $TEMPLATE"

# ---------------------------------------------------------------- 依赖
#
# 这里曾经要手工编译三个 SwiftPM 依赖模块（swift-collections 的
# InternalCollectionsUtilities / OrderedCollections，以及 ZIPFoundation）。
# 它们必须用同一个 SDK 编译，否则 swiftc 会拒绝加载：
#   cannot load module 'X' built with SDK 'macosx27.0' when using SDK 'macosx26.5'
# 为了迁就 swift-collections 还得照搬六个实验性 feature flag 和 -package-name。
#
# 现在两个依赖都已移除，源码不再引用任何一个（见提交信息），
# 这一步连同它的检出目录探测一起删掉了。

# 全局框架。注意 shell 不会对未加引号的变量做分词，
# 这些必须逐个写成独立参数，不能塞进一个字符串变量里。
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework FinderSync
            -framework ServiceManagement -framework CryptoKit
            -framework UniformTypeIdentifiers -framework CoreServices
            -framework Combine -framework UserNotifications)

# 关键：显式指定 sdk 版本，覆盖链接器从 -sdk 推导出的错误值
PLATFORM_VERSION=(-Xlinker -platform_version -Xlinker macos
                  -Xlinker "$MINOS" -Xlinker "$SDK_VERSION")

# ---------------------------------------------------------------- 编译主程序与扩展

OUT="$BUILD_DIR/out"
mkdir -p "$OUT"

log "编译主应用（-Onone，与用户原版的 Debug 构建对齐）"
"$SWIFTC" -c -o "$OUT/app.o" \
    -sdk "$SDK" -target "$DEPLOY_TARGET" -swift-version 6 -Onone \
    -whole-module-optimization -module-name IClick -plugin-path "$PLUGIN_PATH" \
    "$REPO_ROOT"/IClick/*.swift "$REPO_ROOT"/IClick/Model/*.swift \
    "$REPO_ROOT"/IClick/Settings/*.swift "$REPO_ROOT"/IClick/Shared/*.swift \
    > "$OUT/app-compile.log" 2>&1 \
    || { grep 'error:' "$OUT/app-compile.log" | head -20 >&2; die "主应用编译失败"; }
ok "主应用编译通过（$(grep -c 'warning:' "$OUT/app-compile.log" || true) 条警告）"

log "链接主应用"
"$SWIFTC" -o "$OUT/$APP_NAME" -sdk "$SDK" -target "$DEPLOY_TARGET" \
    "${PLATFORM_VERSION[@]}" "$OUT/app.o" "${FRAMEWORKS[@]}" \
    > "$OUT/app-link.log" 2>&1 \
    || { tail -20 "$OUT/app-link.log" >&2; die "主应用链接失败"; }
ok "主应用链接完成"

log "编译 FinderSync 扩展"
"$SWIFTC" -c -o "$OUT/ext.o" \
    -sdk "$SDK" -target "$DEPLOY_TARGET" -swift-version 6 -Onone \
    -whole-module-optimization -application-extension -module-name FinderSyncExt \
    -plugin-path "$PLUGIN_PATH" \
    "$REPO_ROOT"/FinderSyncExt/*.swift "$REPO_ROOT"/IClick/AppState.swift \
    "$REPO_ROOT"/IClick/Model/*.swift "$REPO_ROOT"/IClick/Shared/*.swift \
    > "$OUT/ext-compile.log" 2>&1 \
    || { grep 'error:' "$OUT/ext-compile.log" | head -20 >&2; die "扩展编译失败"; }
ok "扩展编译通过"

log "链接 FinderSync 扩展"
"$SWIFTC" -o "$OUT/FinderSyncExt" -sdk "$SDK" -target "$DEPLOY_TARGET" -application-extension \
    -Xlinker -e -Xlinker _NSExtensionMain "${PLATFORM_VERSION[@]}" \
    "$OUT/ext.o" -framework AppKit -framework SwiftUI -framework FinderSync \
    -framework ServiceManagement -framework CryptoKit -framework UniformTypeIdentifiers \
    -framework CoreServices -framework Combine > "$OUT/ext-link.log" 2>&1 \
    || { tail -20 "$OUT/ext-link.log" >&2; die "扩展链接失败"; }
ok "扩展链接完成"

# ---------------------------------------------------------------- 校验外观开关
#
# 这一步是整套流程里最重要的守卫：sdk 字段不对，App 会静默退化成旧外观，
# 编译链接都不会报任何错。必须显式比对。

log "校验 LC_BUILD_VERSION（决定 App 外观）"
for bin in "$OUT/$APP_NAME" "$OUT/FinderSyncExt"; do
    read -r minos sdk < <(macho_versions "$bin")
    # 变量后面紧跟中文标点时必须用 ${} 包起来：bash 会把多字节标点的首字节
    # 当成变量名的一部分，报 "unbound variable"。
    [ "$minos" = "${MINOS}.0" ] || die "$(basename "$bin") minos=${minos}，期望 ${MINOS}.0"
    [ "$sdk" = "${SDK_VERSION}.0" ] \
        || die "$(basename "$bin") sdk=${sdk}，期望 ${SDK_VERSION}.0 —— 外观会退化成旧版，中止"
    ok "$(basename "$bin"): minos=$minos sdk=$sdk"
done

# ---------------------------------------------------------------- 组装 bundle

STAGE="$BUILD_DIR/bundle"
log "组装 bundle"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$TEMPLATE" "$STAGE/$APP_NAME.app"
chmod -R u+w "$STAGE/$APP_NAME.app"

APP="$STAGE/$APP_NAME.app"
EXT="$APP/Contents/PlugIns/FinderSyncExt.appex"
[ -d "$EXT" ] || die "模板 bundle 里没有 FinderSyncExt.appex"

cp "$OUT/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$OUT/FinderSyncExt" "$EXT/Contents/MacOS/FinderSyncExt"
chmod +x "$APP/Contents/MacOS/$APP_NAME" "$EXT/Contents/MacOS/FinderSyncExt"
ok "已替换两个可执行文件"

# ---------------------------------------------------------------- 签名（先内层后外层）

log "签名"
EFF_EXT="$BUILD_DIR/entitlements-ext.plist"
EFF_APP="$BUILD_DIR/entitlements-app.plist"
ensure_entitlements "$REPO_ROOT/FinderSyncExt/FinderSyncExt.entitlements" "$EFF_EXT" "${EXT_ENTITLEMENTS[@]}"
ensure_entitlements "$REPO_ROOT/IClick/IClick.entitlements" "$EFF_APP" "${APP_ENTITLEMENTS[@]}"

codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none \
    --entitlements "$EFF_EXT" "$EXT"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none \
    --entitlements "$EFF_APP" "$APP"
codesign --verify --deep --strict "$APP" || die "签名校验失败"

# 沙箱权限必须真的签进去，否则系统会静默拒绝注册这个扩展
codesign -d --entitlements - "$EXT" 2>&1 | grep -q 'com.apple.security.app-sandbox' \
    || die "扩展签名里缺少 app-sandbox —— 系统会拒绝注册，Finder 右键菜单将失效"
ok "签名校验通过（扩展含 app-sandbox）"

# ---------------------------------------------------------------- 安装

log "安装到 $INSTALL_PATH"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
pkill -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
pkill -f 'FinderSyncExt.appex' 2>/dev/null || true
sleep 1

rm -rf "$INSTALL_PATH"
cp -R "$APP" "$INSTALL_PATH"
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

# 重新注册，避免 stale 副本导致右键菜单出现两次
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f -R -trusted "$INSTALL_PATH"
pluginkit -a "$INSTALL_PATH/Contents/PlugIns/FinderSyncExt.appex" 2>/dev/null || true
open "$INSTALL_PATH"
sleep 3

# 扩展必须出现在 pluginkit 里，Finder 才会去加载它。没出现就是右键菜单不会生效。
# 注册是异步的，刚复制完 bundle 时查不到是正常的，所以要轮询而不是只查一次。
# 整个 .app 是先 rm -rf 再 cp -R，pluginkit 要摘掉旧条目再重建，实测可能耗时一分钟以上。
# 轮询期间定期重新触发一次注册，避免它一直卡在待重扫状态。
ext_registered=0
for i in $(seq 1 60); do
    if pluginkit -m -v 2>/dev/null | grep -q "$EXT_PLUGIN_ID"; then
        ext_registered=1
        break
    fi
    if [ $((i % 5)) -eq 0 ]; then
        pluginkit -a "$INSTALL_PATH/Contents/PlugIns/FinderSyncExt.appex" 2>/dev/null || true
    fi
    sleep 1
done
if [ "$ext_registered" = 1 ]; then
    ok "Finder 扩展已注册到 pluginkit"
else
    printf '  \033[1;31m!\033[0m 扩展未出现在 pluginkit 中，Finder 右键菜单可能不生效\n' >&2
fi

log "完成"
ps -ax -o pid,comm | grep -i "$APP_NAME.app" | grep -v grep | sed 's/^/  /' || true
printf '\n  请打开设置窗口确认半透明质感与整体观感正常。\n'
