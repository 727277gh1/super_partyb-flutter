#!/usr/bin/env bash
# 守卫：GitHub Actions workflow 的 step 不能被注释吞掉。
#
# ## 为什么需要它
#
# `.github/workflows/release.yml` 曾把
#
#     # 四端产物合并到同一目录；merge-multiple 让它们平铺……
#     - uses: actions/download-artifact@v4
#
# 写成了**同一行**——于是 `- uses:` 落在注释里，整个 step 消失。后果：
# release job 的 `gh release create` 引用的四个产物文件全不存在，**打 tag 时
# 必定失败**，而 `ls -lh` 只打印空目录、不报错，缺陷被静默吞掉。
#
# 这类错误 `yaml.safe_load` **不报错**（注释是合法 YAML），所以语法检查抓不到；
# 只有「step 是否存在」这一语义检查才能发现。
#
# ## 两道检查
#
# 1. **注释里出现 step 标记**（`- uses:` / `- name:`）——零依赖的正则检查，
#    直接命中本次缺陷的形态，且不需要 yaml 模块。
# 2. **结构断言**（需 PyYAML，缺失则跳过并提示）——release job 必须含
#    `download-artifact`，且 `actions/checkout` 的 `with` 只能挂「拉全历史」
#    那一组键（`with` 错挂到 checkout 上正是同一缺陷的另一面）。
#
# ⚠️ 关于 checkout 的 `with`（issue #47 调整）：原来断言「checkout 不得有
# `with`」。但 release notes 现在用 `git log <上一个 tag>..HEAD` 生成，
# **必须** `fetch-depth: 0` + `fetch-tags: true`——否则 tag 与历史都拿不到，
# 变更列表静默变空。故改成「只允许这一组键」：缺陷的形态（download-artifact
# 的 `with: merge-multiple` 因 step 边界写坏而挂到 checkout 上）仍会被拦住，
# 因为那组键不在允许集里。
#
# 与 check_layering.sh 同样只用仓库根作为工作目录，保证本地与 CI 跑的是同一
# 条命令（见 AGENTS.md「常用命令」）。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d .github/workflows ]; then
  echo "❌ 未找到 .github/workflows（工作目录不对？）"
  exit 1
fi

python3 - <<'PY'
import glob
import re
import sys

# step 标记：`- uses:` / `- name:`（允许列表项前有缩进）。
STEP_MARKER = re.compile(r'^\s*#.*?(?:^|\s)-\s+(?:uses|name):\s*\S')
COMMENT_LINE = re.compile(r'^\s*#')

failed = False
files = sorted(glob.glob('.github/workflows/*.yml') +
               glob.glob('.github/workflows/*.yaml'))

if not files:
    print('❌ .github/workflows 下没有 workflow 文件')
    sys.exit(1)

# ── 检查 1：注释吞掉 step 标记 ──────────────────────────────────────
for path in files:
    with open(path, encoding='utf-8') as fh:
        for lineno, line in enumerate(fh, 1):
            if not COMMENT_LINE.match(line):
                continue
            if STEP_MARKER.search(line):
                print(f'❌ {path}:{lineno} step 标记落在注释里——'
                      f'该 step 会被静默丢弃：')
                print(f'     {line.rstrip()}')
                failed = True

# ── 检查 2：release job 的结构断言（需 PyYAML）──────────────────────
try:
    import yaml
except ImportError:
    print('⚠️  未安装 PyYAML，跳过结构断言（注释检查仍已执行）')
else:
    path = '.github/workflows/release.yml'
    with open(path, encoding='utf-8') as fh:
        doc = yaml.safe_load(fh)

    steps = doc.get('jobs', {}).get('release', {}).get('steps')
    if steps is None:
        print(f'❌ {path}: 没有 release job 或它没有 steps')
        failed = True
    else:
        uses = [s.get('uses', '') for s in steps]

        if 'actions/download-artifact@v4' not in uses:
            print(f'❌ {path}: release job 缺 actions/download-artifact@v4'
                  f'（产物不会被下载，gh release create 必失败）')
            failed = True

        # `with` 错挂到 checkout 上：说明某个 step 的边界被写坏了。
        #
        # 只允许「拉全历史」这一组键（release notes 需要 `git log` 拿 tag）；
        # 若出现 `merge-multiple` 这类**属于 download-artifact** 的键，
        # 说明它后面那个 step 被注释吞掉了（本守卫要抓的历史缺陷）。
        ALLOWED_CHECKOUT_WITH = {'fetch-depth', 'fetch-tags'}
        for step in steps:
            if not step.get('uses', '').startswith('actions/checkout'):
                continue
            with_keys = set(step.get('with', {}))
            extra = with_keys - ALLOWED_CHECKOUT_WITH
            if extra:
                print(f'❌ {path}: actions/checkout 的 with 含意外键 {sorted(extra)}'
                      f'——很可能是后一个 step 的 with 错挂上来（step 边界被写坏）')
                failed = True

        # 每个 step 必须有 name 或 uses，否则是残缺条目。
        for i, step in enumerate(steps, 1):
            if not step.get('name') and not step.get('uses'):
                print(f'❌ {path}: release job 第 {i} 个 step 既无 name 也无 uses')
                failed = True

if failed:
    sys.exit(1)

print(f'✅ workflow step 结构检查通过（{len(files)} 个文件）')
PY
