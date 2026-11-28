#!/usr/bin/env bash
# 守卫：Android 的 debug/release 回退签名必须是**仓库内那一把固定密钥**（§6.95）。
#
# ## 它防的是什么
#
# 「每次安装都提示签名不一致」不是构建配置写错，而是**没配**：`signingConfigs.debug`
# 默认指向 `~/.android/debug.keystore`，这个文件由 AGP 按需 `keytool` **现场生成**
# ——口令固定（`android`），但**密钥对随机**。于是每台开发机、每次干净的 CI runner
# 都拿到一把不同的密钥。Android 拒绝覆盖签名不同的同包名应用
# （`INSTALL_FAILED_UPDATE_INCOMPATIBLE`，各家 ROM 文案「签名不一致」），用户每次
# 下载新 APK 都得先卸载旧的。
#
# 实测两次相邻 CI 产物（2026-11）：签名证书分别是 `23:E0:80:BE:…` 与
# `C2:25:66:4D:…`，都是 `CN=Android Debug`——同一份代码，两把钥匙。
#
# 修法是把一把**调试**密钥入库（口令是 Android 公开约定，不含机密），并让
# `app/build.gradle.kts` 显式覆盖 debug 配置指向它。本守卫盯住这条接线：
#
#   1. 文件在、且**真的入库了**（`.gitignore` 有 `!` 例外，容易被后面的规则盖掉）
#   2. Gradle 确实覆盖了 debug 签名（不是「文件在但没人用」）
#   3. 指纹等于下面钉住的常量（被重新生成 = 全员又要卸载重装一次）
#   4. 可选：传入 APK 路径时，校验产物**实际**用的就是这把钥匙
#
# ## 为什么指纹要钉成常量
#
# 少了这一条，「有人手滑 `rm` 后重新生成」会静默通过：文件还在、Gradle 也仍在用，
# 但签名换了。这类事故的发现成本极高（要等到用户装不上），故宁可让守卫红一次。
#
# ## 用法
#
#   bash tools/check_android_signing.sh                     # 静态配置检查
#   bash tools/check_android_signing.sh <apk>               # 追加：产物签名比对
#
# 缺 `keytool` / `python3` 时跳过对应检查并打印提示——守卫的存在感不应该变成
# 「没装 JDK 就交不了代码」（CI 两者都有，故 CI 上是全量检查）。
set -euo pipefail

cd "$(dirname "$0")/.."

KEYSTORE=apps/spb_mobile/android/debug.keystore
GRADLE=apps/spb_mobile/android/app/build.gradle.kts

# 入库的那把调试密钥的证书指纹（不带冒号，小写）。
#
# ⚠️ 改它 = 换密钥 = **所有装了旧包的人必须卸载重装**。若确实要换，先读 §6.95
# 的「换密钥的代价」，连同文档一起改，别只改这一行。
EXPECTED_SHA256="1089ac1f3ad576d62348fdfb982412f18bdcb11d124bbf115b7462f879ce98ef"

fail() {
  echo "❌ $*" >&2
  exit 1
}

warn() { echo "⚠️ $*" >&2; }

# ── 1) 文件存在且在库里 ────────────────────────────────────────────────
[ -f "$KEYSTORE" ] || fail "缺少 $KEYSTORE —— 见 §6.95（该文件**刻意入库**，不是密钥泄露）"

git ls-files --error-unmatch "$KEYSTORE" >/dev/null 2>&1 ||
  fail "$KEYSTORE 存在但**未入库**。它必须被 git 跟踪：只在本机存在等于没修，CI 还是每次换钥匙"

# `git check-ignore` 命中（exit 0）= 被忽略；后面的 `!` 负向规则容易被子目录
# `.gitignore` 里的 `**/*.keystore` 盖掉，故这里显式断言。
if git check-ignore -q "$KEYSTORE"; then
  fail "$KEYSTORE 被 .gitignore 忽略了（检查 apps/spb_mobile/android/.gitignore 的 '!/debug.keystore' 是否在 '**/*.keystore' 之后）"
fi

# ── 2) Gradle 真的在用它 ───────────────────────────────────────────────
[ -f "$GRADLE" ] || fail "未找到 $GRADLE"
grep -q 'getByName("debug")' "$GRADLE" ||
  fail "$GRADLE 没有覆盖 debug 签名配置（找不到 getByName(\"debug\")）—— 那样仍会用 ~/.android/debug.keystore"
grep -q 'storeFile = repoDebugKeystoreFile' "$GRADLE" ||
  fail "$GRADLE 的 debug 签名没有指向 debug.keystore（找不到 storeFile = repoDebugKeystoreFile）"

# ── 3) 指纹没变 ────────────────────────────────────────────────────────
normalize_fp() { tr -d ':' | tr 'A-F' 'a-f' | tr -d '[:space:]'; }

if command -v keytool >/dev/null 2>&1; then
  actual_fp=$(
    keytool -list -v -keystore "$KEYSTORE" -storepass android -alias androiddebugkey 2>/dev/null |
      sed -nE 's/^[[:space:]]*SHA256:[[:space:]]*//p' | head -1 | normalize_fp
  )
  [ -n "$actual_fp" ] ||
    fail "读不出 $KEYSTORE 的指纹（口令或别名被改动过？约定是 storepass/keypass=android、alias=androiddebugkey）"
  if [ "$actual_fp" != "$EXPECTED_SHA256" ]; then
    fail "调试密钥指纹变了：
    实际 $actual_fp
    期望 $EXPECTED_SHA256
  这意味着密钥被重新生成过：已安装旧包的用户会「签名不一致」装不上。
  要么用 git 还原 $KEYSTORE，要么确认换密钥后同步改本脚本常量 + §6.95。"
  fi
  echo "✅ 调试密钥指纹一致（${EXPECTED_SHA256:0:16}…）"
else
  warn "未找到 keytool，跳过指纹比对（其余检查已通过）"
fi

# ── 4) 可选：校验产物实际签名 ──────────────────────────────────────────
#
# 不用 `apksigner`：它属于 build-tools，路径随 SDK 版本漂移，且首次用于 CI 时
# 只往 stderr 吐错（实测 `apksigner 读不出 … 的签名证书` 而拿不到任何细节）。
# APK 的证书就在 **APK Signing Block**（v2 / v3）里，用 python3 直接解：
# 纯标准库、无 SDK 依赖，得到的 SHA-256 与 `apksigner --print-certs` 一致
# （都是证书 DER 的 SHA-256）。
if [ "$#" -ge 1 ]; then
  apk=$1
  [ -f "$apk" ] || fail "未找到 APK：$apk"

  if ! command -v python3 >/dev/null 2>&1; then
    warn "未找到 python3，跳过产物签名比对"
  else
    apk_sha=$(python3 - "$apk" <<'PYAPK'
import hashlib
import struct
import sys

path = sys.argv[1]
data = open(path, "rb").read()

# 1) 定位 central directory（EOCD 在文件尾部，后面可能还有注释，故从后往前找）。
eocd = data.rfind(b"PK\x05\x06")
if eocd < 0:
    sys.exit("不是 zip/APK")
cd_off = struct.unpack("<I", data[eocd + 16 : eocd + 20])[0]

# 2) APK Signing Block 紧贴 central directory 之前，尾部 16 字节是魔数。
if cd_off < 24 or data[cd_off - 16 : cd_off] != b"APK Sig Block 42":
    sys.exit("没有 APK Signing Block（只有 v1/jarsigner 签名？）")

size_in_footer = struct.unpack("<Q", data[cd_off - 24 : cd_off - 16])[0]
block_start = cd_off - size_in_footer - 8
pairs = data[block_start + 8 : cd_off - 24]


def take_lp(buf, off):
    """取一个 uint32 长度前缀的切片。"""
    (n,) = struct.unpack("<I", buf[off : off + 4])
    return buf[off + 4 : off + 4 + n], off + 4 + n


# 3) 拆出 id → value 的成对列表。
found = {}
i = 0
while i < len(pairs):
    (plen,) = struct.unpack("<Q", pairs[i : i + 8])
    (pid,) = struct.unpack("<I", pairs[i + 8 : i + 12])
    found[pid] = pairs[i + 12 : i + 8 + plen]
    i += 8 + plen

# 4) v2(0x7109871a) / v3(0xf05368c0)：signers → signer → signed data →
#    [digests, certificates, attributes]，证书是每项长度前缀的 DER。
for pid in (0x7109871A, 0xF05368C0):
    value = found.get(pid)
    if value is None:
        continue
    signers, _ = take_lp(value, 0)
    signer, _ = take_lp(signers, 0)
    signed_data, off = take_lp(signer, 0)
    _digests, off = take_lp(signed_data, 0)
    certs_blob, _ = take_lp(signed_data, off)
    cert, _ = take_lp(certs_blob, 0)
    print(hashlib.sha256(cert).hexdigest())
    break
else:
    sys.exit("签名块里没有 v2/v3 证书")
PYAPK
    ) || fail "无法从 $apk 解析签名证书（详见上面的原因）"

    if [ "$apk_sha" != "$EXPECTED_SHA256" ]; then
      fail "产物签名与仓库内的调试密钥不一致：
    产物 ${apk_sha}
    期望 $EXPECTED_SHA256
  说明这次构建没用上 debug.keystore（回退到了 ~/.android/debug.keystore？）"
    fi
    echo "✅ 产物签名与仓库内调试密钥一致"
  fi
fi

echo "✅ Android 签名检查通过（§6.95）"
