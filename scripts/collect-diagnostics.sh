#!/usr/bin/env bash
#
# collect-diagnostics.sh —— 把排查 IClick 问题需要的文件打包到桌面
#
# 产物：~/Desktop/IClick-diagnostics-<时间>.tar.gz
# 注意：日志和配置里会包含你操作过的文件路径。分享前请自行检查/脱敏。
#
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Desktop/IClick-diagnostics-$STAMP"
GROUP_DIR="$HOME/Library/Group Containers/group.33WRMMC62L.cn.anwen.IClick"
APP_DIR="$HOME/Library/Application Support/IClick"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

mkdir -p "$OUT"

cp "$APP_DIR/diagnostics.log" "$OUT/app-diagnostics.log" 2>/dev/null || true
cp "$APP_DIR/diagnostics.log.1" "$OUT/app-diagnostics.log.1" 2>/dev/null || true
cp "$GROUP_DIR/diagnostics-extension.log" "$OUT/extension-diagnostics.log" 2>/dev/null || true
cp "$GROUP_DIR/diagnostics-extension.log.1" "$OUT/extension-diagnostics.log.1" 2>/dev/null || true
cp "$APP_DIR/SharedSettings.plist" "$OUT/SharedSettings.plist" 2>/dev/null || true

{
    echo "== date =="
    date
    echo
    echo "== sw_vers =="
    sw_vers
    echo
    echo "== IClick processes =="
    ps -ax -o pid,etime,command | grep -i iclick | grep -v grep || true
    echo
    echo "== pluginkit =="
    pluginkit -m -v -p com.apple.FinderSync | grep -i iclick || true
    echo
    echo "== LaunchServices copies =="
    "$LSREGISTER" -dump 2>/dev/null | grep -E "^path:.*Iclick.app" || true
    echo
    echo "== login item =="
    sfltool dumpbtm 2>/dev/null | grep -B7 -A2 "Bundle Identifier: cn.anwen.IClick" || true
    echo
    echo "== preferences (menu bar flag) =="
    defaults read group.33WRMMC62L.cn.anwen.IClick showMenuBarExtra 2>/dev/null || true
    defaults read cn.anwen.IClick showMenuBarExtra 2>/dev/null || true
    echo
    echo "== app-reported Full Disk Access =="
    # 以主应用自己的探测结果为准：TCC 授权按进程归属，shell 的读权限不代表 App 的
    grep -E "app launch .*fda=" "$APP_DIR/diagnostics.log" 2>/dev/null | tail -5 || true
    echo
    echo "== TCC.db readability from this shell (not authoritative) =="
    if head -c 1 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1; then
        echo "readable from this shell"
    else
        echo "not readable from this shell (terminal lacks FDA; this does not imply the app lacks it)"
    fi
} > "$OUT/system.txt" 2>&1

/usr/bin/tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
rm -rf "$OUT"
echo "已生成: $OUT.tar.gz"
