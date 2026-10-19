#!/usr/bin/env bash
# 把 Linux 桌面端 bundle 的非系统依赖库复制进 bundle/lib，使其可独立分发。
#
# ## 为什么需要这个脚本
#
# `hotkey_manager` 的 Linux 实现链接 `libkeybinder-3.0.so.0`。该库在多数发行版
# 不是默认安装项（Debian/Ubuntu 需要 `libkeybinder-3.0-dev`）。若开发机上它装在
# 非标准前缀（如本仓库约定的 `~/.local/opt`），构建产物会把该路径写进 RUNPATH，
# 结果**只在开发机可运行**——分发出去就报 `cannot open shared object file`。
#
# 本脚本把这些库复制进 `bundle/lib/`（主程序的 RUNPATH 已含 `$ORIGIN/lib`），
# 使 bundle 自包含。
#
# 用法：bash tools/bundle_linux_deps.sh [bundle目录]
set -euo pipefail

BUNDLE="${1:-apps/spb_desktop/build/linux/x64/release/bundle}"

if [ ! -d "$BUNDLE" ]; then
  echo "❌ 找不到 bundle 目录：$BUNDLE"
  echo "   先执行：cd apps/spb_desktop && flutter build linux --release"
  exit 1
fi

# 需要随包分发的非系统库。新增桌面插件依赖时在此登记。
EXTRA_LIBS=(
  "libkeybinder-3.0.so.0"
)

copied=0
for lib in "${EXTRA_LIBS[@]}"; do
  # 已在 bundle 里则跳过
  if [ -e "$BUNDLE/lib/$lib" ]; then
    echo "  ✓ $lib 已在 bundle 中"
    continue
  fi

  # 在动态链接器的搜索路径里找。
  # 注意 ldconfig 位于 /sbin，而普通用户的 PATH 通常不含它，必须写绝对路径。
  src=$(/sbin/ldconfig -p 2>/dev/null | awk -v l="$lib" '$1 == l {print $NF; exit}' || true)
  if [ -z "$src" ] || [ ! -e "$src" ]; then
    # 回退：本地前缀（本仓库约定的免 sudo 安装位置）。
    # 用 find 而非 glob：无匹配时 glob 会保留字面量，配合 set -u 易出错。
    src=$(find "$HOME/.local/opt" -maxdepth 2 -name "$lib" -type f 2>/dev/null | head -1 || true)
  fi

  if [ -z "$src" ] || [ ! -e "$src" ]; then
    echo "  ⚠️  $lib 未找到，跳过（运行时可能报缺库）"
    continue
  fi

  cp -L "$src" "$BUNDLE/lib/$lib"
  echo "  ✓ 复制 $lib  ← $src"
  copied=$((copied + 1))
done

# 修正插件 RUNPATH，使其从 bundle 内解析依赖。
#
# ⚠️ 关键细节：主程序位于 bundle/，插件位于 bundle/lib/，两者 $ORIGIN 不同。
#   - 主程序：需要 "$ORIGIN/lib"（bundle/spb_desktop → bundle/lib）
#   - 插件：  需要 "$ORIGIN"（bundle/lib/xxx.so → bundle/lib）
# 若给插件也写 "$ORIGIN/lib"，实际指向 bundle/lib/lib（不存在），
# 加载器会回退到开发机的绝对路径——即「本地能跑、分发即挂」。
if command -v patchelf >/dev/null 2>&1; then
  # 主程序
  for exe in "$BUNDLE"/*; do
    [ -f "$exe" ] || continue
    [ -x "$exe" ] || continue
    cur=$(patchelf --print-rpath "$exe" 2>/dev/null || true)
    case "$cur" in
      *'$ORIGIN/lib'*) ;;
      *) patchelf --set-rpath "\$ORIGIN/lib${cur:+:$cur}" "$exe" 2>/dev/null || true ;;
    esac
  done
  # 插件（在 lib/ 内，用 $ORIGIN 而非 $ORIGIN/lib）
  for so in "$BUNDLE"/lib/*.so*; do
    [ -f "$so" ] || continue
    cur=$(patchelf --print-rpath "$so" 2>/dev/null || true)
    # 去掉开发机上的绝对路径前缀，避免分发后仍指向不存在的目录
    cleaned=$(echo "$cur" | tr ':' '\n' | grep -v '^/home/' | paste -sd: - || true)
    new="\$ORIGIN${cleaned:+:$cleaned}"
    if [ "$cur" != "$new" ]; then
      patchelf --set-rpath "$new" "$so" 2>/dev/null || true
    fi
  done
  echo "  ✓ 已修正 RUNPATH（主程序 \$ORIGIN/lib，插件 \$ORIGIN）"
else
  echo "  ⚠️  未安装 patchelf，插件仍依赖绝对路径。"
  echo "     安装：sudo apt install patchelf（或 apt-get download + dpkg-deb -x 到 ~/.local/opt）"
fi

echo ""
echo "完成（新增 $copied 个库）。bundle：$BUNDLE"
echo "自检：ldd $BUNDLE/spb_desktop | grep 'not found'"
