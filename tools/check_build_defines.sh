#!/usr/bin/env bash
# 守卫：workflow 的发布构建必须传构建期地址参数（`--dart-define`）。
#
# ## 为什么需要它（真实缺陷，2026-10）
#
# 用户下载 CI 产出的 Windows 包，运行时提示「远程计算机拒绝网络连接」。
# 根因不是参数写错，而是 **`ci.yml` 的 `build-windows` job 一个 define 都没传**
# （整文件 `dart-define` 零命中）。于是产物用的是 `SpbEnv` 的编译期默认值：
#
#     apiBaseUrl      → http://127.0.0.1:8000
#     ufsBaseUrl      → http://127.0.0.1:9000/ufs
#     oidcIssuer      → http://127.0.0.1:3000/idp
#
# 客户端去连用户自己机器的 8000 端口 —— 那里什么都没有，于是 ECONNREFUSED
# 被 Dio 包成「连接被拒绝」。**包能启动、界面正常、就是所有请求都失败**，
# 没有任何编译期或测试期信号：`dart analyze` 全绿、3400+ 用例全绿、
# Windows 构建成功。这正是本仓库反复出现的那类「绿不代表对」的缺陷
# （同 §6.21 的 codegen 漂移、§6.26 的 analysis_options 未生效）。
#
# ## 为什么 `release.yml` 是对的、`ci.yml` 是错的
#
# release.yml 有独立的 `config` job 解析「dispatch 输入 > 仓库 Variables >
# 内置默认值」，四个平台各 5 条 define 全部传了。ci.yml 只验证「能不能编译」，
# 却把产物**上传成 Actions artifact 供人下载运行**（`retention-days: 7`）——
# 于是「验证用的包」被当成「能用的包」下载了。两者的意图不同，产物却是同一种。
#
# ## 检查什么
#
# 1. **静态**：每个 `flutter build <platform> --release` 所在的 job，必须在该
#    job 内出现 `--dart-define=SPB_API_BASE_URL`。按 job 粒度而非按 step 粒度
#    ——define 可以在 `env:` 里给、由脚本拼装（release.yml 就是这么做的），
#    按 step 匹配会误报。
# 2. **动态（仅当本地产物存在时）**：AOT 快照里不得残留默认地址
#    `127.0.0.1:8000`。这是**直接证据**——静态检查只能证明「传了参数」，
#    这一条证明「参数真的进了二进制」。
#
# ## 为什么动态检查是可靠的（实测）
#
# `--dart-define` 的值会**替换**默认值，且未使用的默认值字符串被 tree-shake
# 掉。实测同一份代码：
#
#     flutter build linux --release                              → strings | grep 127.0.0.1:8000 → 1
#     flutter build linux --release --dart-define=SPB_API_BASE_URL=https://example.test/pba
#                                                                → 1 处 0 个，example.test/pba 1 个
#
# 故「产物含 127.0.0.1:8000」等价于「这个包连的是本机」。
#
# ## 不检查什么
#
# - **不校验地址的具体值**：那是部署方的属性（`vars` / dispatch 输入），
#   守卫不该知道生产域名（同 `sync-to-github.sh` 的「值无关」取向）。
# - **不检查 iOS**：必须 Apple Developer 账号，当前不出包。
# - **不检查 UFS / OIDC 的 define 是否齐全**：api 是「连不上就什么都做不了」的
#   那一个，其余缺失是功能降级（OIDC 缺失 → 登录不可用，其余正常）。要求全部
#   齐全会让守卫在「故意只配 api」的场景误报。
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

# `flutter build <platform> --release`（允许 `cd apps/xxx &&` 前缀与续行）。
BUILD = re.compile(r'flutter\s+build\s+([a-z]+)\s+[^\n]*--release')
# 必传的那一个 define。api 是「连不上就什么都做不了」的根。
REQUIRED_DEFINE = '--dart-define=SPB_API_BASE_URL'

failed = False
checked = 0

for path in sorted(glob.glob('.github/workflows/*.yml') +
                   glob.glob('.github/workflows/*.yaml')):
    with open(path, encoding='utf-8') as fh:
        text = fh.read()

    if 'flutter build' not in text:
        continue

    # 按 job 切块：顶层 `  <name>:` 到下一个同缩进的键。用文本切而非 PyYAML
    # 是为了零依赖，且要检查的正是「原始文本里有没有这个字符串」——解析成
    # dict 后注释与 shell 脚本体都会变成字符串，反而更难按 job 归属。
    jobs = re.split(r'\n  (?=[a-zA-Z0-9_-]+:)', text)
    for job in jobs:
        if not BUILD.search(job):
            continue
        head = job.split('\n', 1)[0].strip().rstrip(':')
        checked += 1

        platforms = sorted(set(BUILD.findall(job)))
        if REQUIRED_DEFINE not in job:
            print(f'❌ {path} 的 job `{head}` 执行了 '
                  f'flutter build {"/".join(platforms)} --release，'
                  f'但**没有传 {REQUIRED_DEFINE}**')
            print('   后果：产物用 SpbEnv 默认值 http://127.0.0.1:8000，'
                  '用户运行时报「连接被拒绝」，')
            print('   而 analyze / test / 构建全部是绿的。')
            print('   修法：按 release.yml 的 config job 解析出地址再传，'
                  '或在该 job 内加 env + 拼参数。')
            failed = True
        else:
            print(f'✅ {path} 的 job `{head}` 已传 {REQUIRED_DEFINE}')

if failed:
    sys.exit(1)

if checked == 0:
    print('❌ 未找到任何 `flutter build <platform> --release`——'
          '守卫会静默空转（workflow 结构变了？）')
    sys.exit(1)

print(f'✅ 构建参数检查通过（{checked} 个 release 构建 job 均传了 api 地址）')
PY

# ── 动态检查：本地产物里不得残留默认地址 ────────────────────────────
# AOT 快照的位置：Linux `bundle/lib/libapp.so`，Windows `Release/data/app.so`，
# macOS `*.app/Contents/Frameworks/App.framework/Resources/app`。
SNAPSHOTS=(
  apps/spb_desktop/build/linux/x64/release/bundle/lib/libapp.so
  apps/spb_desktop/build/windows/x64/runner/Release/data/app.so
)

found_any=0
for snap in "${SNAPSHOTS[@]}"; do
  [ -f "$snap" ] || continue
  found_any=1
  # 用 grep -c 而非 grep -q：后者在 pipefail 下会因 SIGPIPE 提前退出（141）。
  n=$(strings -a "$snap" | grep -c '127\.0\.0\.1:8000' || true)
  if [ "$n" -gt 0 ]; then
    echo "❌ $snap 里残留默认地址 127.0.0.1:8000（$n 处）"
    echo "   这个包运行时会去连本机 8000 端口——用户看到的就是「连接被拒绝」。"
    echo "   请确认构建时传了 --dart-define=SPB_API_BASE_URL=<真实地址>。"
    exit 1
  fi
  echo "✅ $snap 未残留默认地址"
done

if [ "$found_any" -eq 0 ]; then
  echo '⚠️  本机无 release 产物，跳过二进制检查（只做了静态检查）'
fi
