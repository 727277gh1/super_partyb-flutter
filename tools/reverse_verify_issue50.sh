#!/usr/bin/env bash
# 反向验证：逐条把实现改坏，确认对应测试**能抓住**（否则那条用例是空转）。
#
# 针对 issue #50（双栈端点的运行中降级/升级）。这一轮的实现里有 7 处
# 「写反了不会报错」的判定，全部记录在 AGENTS.md §5.1.1 的实现要点表里。
#
# ## 用法
#
#   bash tools/reverse_verify_issue50.sh          # 跑全部（约 1 分钟）
#
# ## 为什么它不是 CI 门禁
#
# 它**就地改源码**（然后还原），放进 CI 会和并行 job 抢文件。CI 里的常驻守卫
# 是 `tools/check_*.sh` + 各自测；本脚本是「改这块实现时手动跑一次」的工具。
#
# ## ⚠️ 锚点会随重构漂移
#
# 每处变异都靠**精确子串**定位。代码改了形态而锚点没跟上时，`mut` 会
# 直接 assert 失败并指出是哪个文件——**不会静默跳过**（静默跳过的反向验证
# 等于给自己发了一张「已验证」的空头支票）。
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/opt/flutter/bin:$HOME/.local/bin:$PATH"

FILES=(
  packages/spb_core/lib/src/endpoints.dart
  packages/spb_api/lib/src/endpoint_health_interceptor.dart
  packages/spb_api/lib/src/http_client.dart
  packages/spb_api/lib/src/sse_client.dart
)

TMP=$(mktemp -d)
i=0
for f in "${FILES[@]}"; do
  cp "$f" "$TMP/$i"
  i=$((i + 1))
done

restore() {
  i=0
  for f in "${FILES[@]}"; do
    [ -f "$TMP/$i" ] && cp "$TMP/$i" "$f"
    i=$((i + 1))
  done
}
trap 'restore; rm -rf "$TMP"' EXIT

# mut <file> <anchor> <replacement>
mut() {
  python3 -c "
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert a in s, '锚点未命中: ' + p + ' —— 实现形态已变，请同步本脚本'
open(p, 'w').write(s.replace(a, b, 1))
" "$@" || {
    echo "  ⚠️ 无法应用变异（锚点漂移），已跳过";
    return 1;
  }
}

# run <label> <pkgdir> <testfile>  —— 期望：至少 1 条用例失败
run() {
  local label="$1" dir="$2" file="$3"
  restore
  local line
  line=$(cd "$dir" && dart test "$file" 2>&1 | grep -oE '\+[0-9]+ -[0-9]+' | tail -1)
  local n="${line#*-}"
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    printf '  ✅ %-56s 失败用例 %s\n' "$label" "$n"
  else
    printf '  ❌ %-56s 未捕获（该用例空转）\n' "$label"
    FAILED=$[${FAILED:-0} + 1]
  fi
}

EP=packages/spb_core/lib/src/endpoints.dart
HE=packages/spb_api/lib/src/endpoint_health_interceptor.dart
HC=packages/spb_api/lib/src/http_client.dart
SC=packages/spb_api/lib/src/sse_client.dart
CT=packages/spb_core/test/endpoint_guard_test.dart
AT=packages/spb_api/test/endpoint_health_interceptor_test.dart
ST=packages/spb_api/test/sse_client_test.dart
FAILED=0

echo "== spb_core: EndpointGuard / SpbEndpoints"

mut $EP '    if (_consecutiveFailures < failureThreshold) return;
    _downgradeNow();' '    if (_consecutiveFailures < failureThreshold) return;'
run "阈值达成却不降级（主症状：切网后永远连不上）" packages/spb_core $CT

mut $EP '    if (kind != EndpointFailureKind.connectivity) return;' '    if (kind == EndpointFailureKind.cancelled) return;'
run "把 4xx/5xx 也计入判据（服务端 500 误触发降级）" packages/spb_core $CT

mut $EP '    if (previous.probeOutcome != EndpointProbeOutcome.upgraded) {
      return previous;
    }' '    // 去掉「仅升级态可降」守卫'
run "去掉「仅升级态可降」守卫（无处可降时反复改结论）" packages/spb_core $CT

mut $EP '    if (previous.apiBaseUrl == next.apiBaseUrl &&
        previous.ufsBaseUrl == next.ufsBaseUrl) {
      return;
    }' '    // 去掉「地址未变则不广播」守卫'
run "无条件广播（结论变了也发，触发无谓重连）" packages/spb_core $CT

mut $EP '    if (resolved.probeOutcome != EndpointProbeOutcome.upgraded) {
      // 保留降级态' '    if (false) {
      // 保留降级态'
run "重探失败时写回（降级结论被盖掉）" packages/spb_core $CT

mut $EP '    if (!_cooledDown()) {' '    if (false) {'
run "取消冷却期（探测风暴 + 刚降就升的抖动）" packages/spb_core $CT

mut $EP '    _lastProbeAt = now();' '    // 不记录探测时刻'
run "去掉独立探测节流（kept 态每个成功都探一次）" packages/spb_core $CT

mut $EP '    _consecutiveFailures = 0;
    final outcome = SpbEndpoints.current.probeOutcome;' '    final outcome = SpbEndpoints.current.probeOutcome;'
run "成功不清零计数（跨好坏两段网络累积）" packages/spb_core $CT

mut $EP '    unawaited(tryUpgrade());' '    // 成功不触发重探'
run "成功不触发重探（启动即 kept 后永远升不上去）" packages/spb_core $CT

echo
echo "== spb_api: 失败分类 / 拦截器顺序 / SSE 换 host"

mut $HE '    case DioExceptionType.badResponse:
    case DioExceptionType.transformTimeout:
    case DioExceptionType.unknown:' '    case DioExceptionType.transformTimeout:
    case DioExceptionType.unknown:
    case DioExceptionType.badResponse:'
run "把 badResponse 归为连接失败" packages/spb_api $AT

mut $HE '    return EndpointFailureKind.connectivity;
    case DioExceptionType.cancel:' '    return EndpointFailureKind.server;
    case DioExceptionType.cancel:'
run "连接超时不计入（永不降级）" packages/spb_api $AT

mut $HE '    final next = resolveBaseUrl();' '    final next = _cached ??= resolveBaseUrl();'
mut $HE '  final String Function() resolveBaseUrl;' '  final String Function() resolveBaseUrl;
  String? _cached;'
run "重写器缓存基地址（降级后仍打旧 host）" packages/spb_api $AT

mut $HE '    if (options.path.startsWith('"'"'http://'"'"') ||
        options.path.startsWith('"'"'https://'"'"')) {
      handler.next(options);
      return;
    }' '    // 去掉「绝对 URL 不重写」守卫'
run "绝对 URL 也被重写（SSE 等显式目标被覆盖）" packages/spb_api $AT

mut $HC '  dio.interceptors.add(EndpointHealthInterceptor());

  // 错误映射拦截器放在最后' '  // 错误映射拦截器放在最后'
run "根本没挂健康拦截器（完全不观测）" packages/spb_api $AT

mut $HC '  dio.interceptors.addAll(interceptors);' '  dio.interceptors.add(EndpointHealthInterceptor());
  dio.interceptors.addAll(interceptors);'
run "顺序错：健康拦截器排在用户拦截器之前" packages/spb_api $AT

mut $SC '    _closedByUser = false;
    _retryCount = 0;' '    _closedByUser = false;
    // 不重置退避计数'
run "resume 不重置退避计数（手动重连只能赌一次）" packages/spb_api $ST

mut $SC '    _retryCount = 0;
    _lastEventId = null;' '    _retryCount = 0;'
run "换 host 保留旧游标（跨后端实例回放会跳事件）" packages/spb_api $ST

mut $SC '    if (path == null || _closedByUser) return false;' '    if (path == null) return false;'
run "用户关闭后仍被降级逻辑唤醒" packages/spb_api $ST

mut $SC '    if (nextBaseUrl == baseUrl) return false;' '    if (false) return false;'
run "同值也重连（无意义抖动）" packages/spb_api $ST

restore
echo
if [ "${FAILED:-0}" -eq 0 ]; then
  echo "✅ 全部反向验证都被捕获（$(grep -c '^run ' "$0") 项）"
else
  echo "❌ 有 $FAILED 项未被捕获——对应用例是空转，需补断言"
  exit 1
fi
