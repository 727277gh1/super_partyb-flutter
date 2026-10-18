#!/usr/bin/env bash
# 守卫：声明了却从未 import 的依赖（issue #36）。
#
# ## 为什么需要它
#
# 本仓库曾有 20+ 个「声明但全仓零 import」的依赖：`spb_models` 的
# freezed/json_serializable 全家桶（模型其实是手写 fromJson）、`spb_platform`
# 的 5 个桌面插件（实现全在 `apps/spb_desktop/lib/bootstrap.dart`）、`spb_data`
# 的 `shared_preferences`（注释明写「不用它」）等。
#
# 危害不是「体积」而是**误导**：读 pubspec 会以为模型用 freezed 生成、以为
# spb_platform 封装了窗口/托盘。且 `spb_platform` 的桌面插件会**经它传递进
# 移动端构建**——移动端注入 `NoopDesktopCapabilities`，用不到却要编译。
#
# ## 判定规则
#
# 对每个成员包的 `dependencies`：取包名，扫该包 `lib/` + `test/` 的
# `import 'package:<name>/...'`。未命中即为「零引用」。
#
# ## 三类**允许**的例外（写死在下方 EXEMPT）
#
# 1. **原生插件**：零 Dart import 但运行时必需（把 native 库打进包）。
#    典型是 `sqlite3_flutter_libs`——drift 在移动端 `DynamicLibrary.open`
#    它，少了它**运行时**才报错（编译/分析都不报）。
# 2. **工作区内部包**：由分层规则（`check_layering.sh`）单独管；且
#    `spb_features` 之类的公开签名可能只用**契约**类型（定义在下层包），
#    而实现由 app 注入——删依赖会破坏调用方。
# 3. **`flutter` SDK**：不是 package 依赖。
#
# ⚠️ 例外必须**显式、可审计**。写成「只要在 EXEMPT 里就不查」而不是
# 「跳过所有常见包」——后者会把真实的新增零引用依赖也一起藏掉。
#
# ## 不检查什么
#
# - **`apps/*`**：两个 app 的 pubspec 里合法地存在「零直接 import」的依赖——
#   原生插件经工作区包间接使用（`file_selector` 走 `spb_platform` 的
#   `DirectoryPicker`、`flutter_secure_storage` 走 `spb_data` 的
#   `SecureTokenStore`），或本身就是资源包（`cupertino_icons` 是字体，
#   不在 Dart 里 import）。本守卫只覆盖 `packages/*`（即 issue #36 的范围）。
# - **dev_dependencies**：测试专用包（`fake_async` / `http_mock_adapter`）
#   常在 `test/` 里用，判定规则已覆盖 test/，但 dev 依赖的「零引用」多为
#   误报（如 `build_runner` 只由命令行驱动），故不纳入。
# - **版本约束**：只查「有没有 import」，不管版本。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d packages ]; then
  echo "❌ 未找到 packages/（工作目录不对？）"
  exit 1
fi

python3 - <<'PY'
import glob
import os
import re
import sys

# 工作区内部包：依赖方向由 check_layering.sh 管，不在这里重复判定。
INTERNAL = {
    'spb_core', 'spb_models', 'spb_api', 'spb_domain', 'spb_data',
    'spb_design', 'spb_ui', 'spb_platform', 'spb_features',
}

# 允许「零 Dart import」的例外（显式、逐条注明理由）。
#
# key 是包名，value 是「为什么它必须留着」。新增例外必须写理由，否则这条
# 守卫就会退化成「谁都能豁免」。
EXEMPT = {
    # 原生插件：把 libsqlite3.so 打进 Android/iOS/macOS/Windows/Linux 包。
    # drift 的 NativeDatabase 在移动端 DynamicLibrary.open('libsqlite3.so')，
    # 少了它**运行时**才失败（编译与分析都不报）。
    # 实测：apk 里 lib/{arm64-v8a,armeabi-v7a,x86_64}/libsqlite3.so 由它提供。
    'sqlite3_flutter_libs': '原生插件：drift 移动端运行时需要 libsqlite3.so',
}

PKG_RE = re.compile(r"^import\s+'package:([a-z0-9_]+)/", re.M)


def declared_deps(pubspec):
    """取 `dependencies:` 段（到下一个顶层键为止）的包名。"""
    with open(pubspec, encoding='utf-8') as fh:
        lines = fh.read().split('\n')
    deps = []
    in_deps = False
    for line in lines:
        if re.match(r'^dependencies:\s*$', line):
            in_deps = True
            continue
        if in_deps and re.match(r'^\S', line):  # 下一个顶层键
            break
        if in_deps:
            m = re.match(r'^  ([a-z0-9_]+):', line)
            if m:
                deps.append(m.group(1))
    return deps


def imported_pkgs(pkg_dir):
    found = set()
    for pat in ('lib/**/*.dart', 'test/**/*.dart', 'bin/**/*.dart'):
        for f in glob.glob(os.path.join(pkg_dir, pat), recursive=True):
            with open(f, encoding='utf-8', errors='ignore') as fh:
                found.update(PKG_RE.findall(fh.read()))
    return found


failed = False
checked = 0
for pubspec in sorted(glob.glob('packages/*/pubspec.yaml')):
    pkg_dir = os.path.dirname(pubspec)
    pkg_name = os.path.basename(pkg_dir)
    deps = declared_deps(pubspec)
    if not deps:
        continue
    imports = imported_pkgs(pkg_dir)

    for dep in deps:
        if dep == 'flutter' or dep in INTERNAL or dep in EXEMPT:
            continue
        checked += 1
        if dep not in imports:
            print(f'❌ {pubspec}: 声明了 `{dep}` 但 {pkg_dir}/lib 与 test 都未 import。')
            print(f'   若确实零引用，删除它；若是原生插件/运行时必需，'
                  f'请加进 check_unused_deps.sh 的 EXEMPT 并注明理由。')
            failed = True

if failed:
    sys.exit(1)

print(f'✅ 依赖引用检查通过（{checked} 个第三方依赖均有 import；'
      f'{len(EXEMPT)} 个显式豁免：{", ".join(sorted(EXEMPT))}）')
PY
