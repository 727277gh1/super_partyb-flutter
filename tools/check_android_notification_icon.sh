#!/usr/bin/env bash
# 守卫：Android 通知小图标 `ic_notification` 必须在**打包后的 APK 里**还在。
#
# ## 它防的是什么
#
# 通知图标是**唯一一张只被 Dart 以字符串引用的 drawable**：
#
#     AndroidNotificationDetails(icon: 'ic_notification')
#
# Flutter 3.47 的 Gradle 插件对 release 强制打开资源压缩（`FlutterPlugin.kt`：
# `isMinifyEnabled = true` + `isShrinkResources = true`）。压缩器只认 Java/XML
# 引用，于是这张图被判定「没人用」→ 从 APK 删掉。
#
# 后果是**全绿但功能失效**：构建成功、安装成功、`debug` 包通知正常，只有
# release 包在发通知时抛 `PlatformException(invalid_icon)`，`LocalNotificationSink`
# 静默降级成 false，用户看到的是「通知发送失败」——成因与「权限被拒」「渠道被关」
# 「系统拦截」完全无法区分（issue #90 想消灭的正是这种含糊）。
#
# 实测（2026-11-20 的 CI release 产物）：`resources.arsc` 里 `ic_launcher` /
# `launch_logo` / `ic_quick_capture` 都在，**只有 `ic_notification` 不见了**；
# 同一天的 debug 产物里它在。差别就是资源压缩。
#
# 修法是 `res/raw/keep.xml` 的 `tools:keep`。本守卫盯住四件事：
#
#   1. keep.xml 在，且 keep 的正是 `@drawable/ic_notification`
#   2. 五个密度的 PNG 都在（少一个只是该密度回退，但通常是生成脚本没跑全）
#   3. Dart 侧 `androidSmallIcon` 的默认值仍是 `ic_notification`（改名后
#      keep 名单会失配，而它不会自己报错）
#   4. 可选：传入 APK 时，`resources.arsc` 里**确实**有这个名字（这是唯一
#      能证明「压缩没把它吃掉」的检查，CI 在构建后跑这一条）
#
# ## 为什么第 4 条必须存在
#
# 前三条全过也可能仍被吃掉：keep 语法写错（`tools:keep` 写成了 `tools:discard`）、
# 文件放错目录（不在 `res/raw/`）、AGP 后续改了压缩策略。只有看产物才算数。
#
# ## 用法
#
#   bash tools/check_android_notification_icon.sh              # 静态检查
#   bash tools/check_android_notification_icon.sh <apk>        # 追加：产物检查
#
# 产物检查用 python3 直接读 `resources.arsc` 的字符串池：不依赖 aapt2
# （路径随 build-tools 版本漂移，且 CI 的 SDK 布局与本地不同）。
set -euo pipefail

cd "$(dirname "$0")/.."

RES=apps/spb_mobile/android/app/src/main/res
KEEP="$RES/raw/keep.xml"
SINK=packages/spb_platform/lib/src/local_notification_sink.dart
GEN=tools/gen_brand_assets.py
ICON=ic_notification
DENSITIES=(mdpi hdpi xhdpi xxhdpi xxxhdpi)

fail() {
  echo "❌ $*" >&2
  exit 1
}

warn() { echo "⚠️ $*" >&2; }

# ── 1) keep 名单 ──────────────────────────────────────────────────────
[ -f "$KEEP" ] || fail "缺少 $KEEP —— release 构建会把 @drawable/$ICON 当未使用资源删掉"

grep -q "tools:keep=\"@drawable/$ICON\"" "$KEEP" ||
  fail "$KEEP 里没有 tools:keep=\"@drawable/$ICON\"（压缩器不会保留它）"

# 反向断言：写成 discard 等于主动删除，比没有更糟。
if grep -q "tools:discard" "$KEEP"; then
  fail "$KEEP 里出现 tools:discard —— 那是删除名单，不是保留名单"
fi

# ── 2) 五个密度 ───────────────────────────────────────────────────────
for d in "${DENSITIES[@]}"; do
  [ -f "$RES/drawable-$d/$ICON.png" ] ||
    fail "缺少 drawable-$d/$ICON.png（跑 tools/gen_brand_assets.py --only notification）"
done

# ── 3) Dart 侧默认值 + 生成脚本，三处名字必须一致 ──────────────────────
default_icon=$(sed -n "s/.*androidSmallIcon = '\([^']*\)'.*/\1/p" "$SINK" | head -1)
[ -n "$default_icon" ] || fail "无法从 $SINK 解析 androidSmallIcon 的默认值（解析规则已过时）"
[ "$default_icon" = "$ICON" ] ||
  fail "Dart 侧 androidSmallIcon='$default_icon'，而 keep 名单保的是 '$ICON'——改名必须同时改三处"

grep -q "$ICON" "$GEN" ||
  fail "$GEN 不再产出 $ICON（图标生成与 keep 名单脱钩）"

# ── 4) 可选：产物里的资源表 ───────────────────────────────────────────
apk="${1:-}"
if [ -z "$apk" ]; then
  echo "✅ 静态检查通过（keep 名单 / 五密度 / 三处名字一致）"
  echo "   提示：传 APK 路径可校验产物 —— bash tools/check_android_notification_icon.sh <apk>"
  exit 0
fi

[ -f "$apk" ] || fail "未找到 APK：$apk"

python3 - "$apk" "$ICON" <<'PYAPK' || fail "产物校验失败（见上面的原因）"
import sys
import zipfile

apk, name = sys.argv[1], sys.argv[2]
try:
    with zipfile.ZipFile(apk) as z:
        data = z.read('resources.arsc')
except KeyError:
    sys.exit('APK 里没有 resources.arsc（不是 Android 包？）')
except zipfile.BadZipFile:
    sys.exit('不是 zip/APK')

# 资源名以 UTF-8 字符串进 `resources.arsc` 的全局字符串池，按名字搜即可。
# 不解析二进制格式：这里只回答「这个名字还在不在」，多解析只会引入版本耦合。
if name.encode() not in data:
    sys.exit(
        f'resources.arsc 里没有 {name}：资源压缩把它删了 —— 通知会在发的时候抛 '
        f'PlatformException(invalid_icon)，而构建/安装全绿。检查 res/raw/keep.xml'
    )
print(f'✅ {apk} 的 resources.arsc 里保留了 {name}')
PYAPK
