import 'dart:async';
import 'dart:math';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

/// 邮箱 magic link 登录的编排：发信 → 等确认 → 兑换授权码 → 交给落盘点。
///
/// ## 为什么在 `spb_features` 而不是 app 装配层
///
/// 这条路径**没有任何平台依赖**：不打开浏览器、不唤起小程序、不监听深链。
/// 全部动作是 HTTP + 一个轮询循环，桌面端与移动端需要的行为完全一致
/// （对比微信一键：那条要用 OpenSDK，只能留在 `apps/spb_mobile`）。
///
/// ## 流程与失败语义
///
/// ```
/// 1. 生成 state + PKCE 并落盘（与浏览器/小程序流程同一份存储）
/// 2. POST {issuer}/api/v1/auth/magic-link  {email}   → requestId
/// 3. 轮询 .../check?request_id= 直到 confirmed / expired / 超时
/// 4. POST .../exchange 换标准 OIDC 授权码（单次消费）
/// 5. onCode(code, pkce) —— 与深链回调同一个落盘点（换 token + 写安全存储）
/// ```
///
/// 第 1 步落盘的唯一用途是「应用被系统回收后仍能完成回调」这一场景与另外两条
/// 路径保持一致；本流程自身不依赖它（确认在浏览器里，回调不经过 App）。
///
/// ## 为什么要 `isActive`
///
/// 等待确认最长可达 [pollTimeout]（默认与令牌 TTL 同为 10 分钟）。用户可能
/// 中途离开登录页或点了别的入口——没有这个钩子，轮询会一直打到超时，
/// 既浪费请求，也可能在用户已经换了登录方式之后把迟到的授权码塞进会话。
///
/// 返回错误文案（null = 成功）。
Future<String?> magicLinkSignIn({
  required MagicLinkClient client,
  required PendingAuthRequestStore store,
  required String email,
  required Future<String?> Function(String code, PkcePair pkce) onCode,

  /// 邮件已发出（此时才开始「请查收」的等待 UI）。
  ///
  /// 服务端对**不存在的邮箱也返回成功**（防枚举），所以这个回调触发时
  /// 不代表邮箱一定存在——文案不能说「邮件已发送」，只能说「如果邮箱已注册」。
  Future<void> Function()? onSent,

  /// 是否继续等待（登录页传 `() => mounted`）。返回 false 时立刻收尾。
  bool Function()? isActive,

  String Function()? stateGenerator,
  PkcePair Function()? pkceGenerator,
  Duration pollInterval = const Duration(seconds: 2),
  Duration pollMaxInterval = const Duration(seconds: 8),
  Duration pollTimeout = const Duration(minutes: 10),
  Future<void> Function(Duration)? sleep,
}) async {
  final trimmed = email.trim();
  if (trimmed.isEmpty) return '请输入邮箱地址';
  // 只做「明显不是邮箱」的本地拦截，格式细节交给服务端（它的判定是权威，
  // 且未来可能放宽；两边各写一套规则必然漂移）。
  if (!trimmed.contains('@')) return '邮箱地址格式不正确';

  final state = (stateGenerator ?? _defaultState)();
  final pkce = (pkceGenerator ?? OidcPkce.generatePair)();
  await store.put(PendingAuthRequest(state: state, pkce: pkce));

  final MagicLinkRequest request;
  try {
    request = await client.request(trimmed);
  } on AuthError catch (e) {
    await store.consume();
    return e.message;
  } catch (e) {
    await store.consume();
    return '无法发起邮箱登录：$e';
  }

  SpbLog.info('已受理邮箱登录请求', {'requestId': request.requestId});
  if (onSent != null) await onSent();

  final polled = await _pollMagicLink(
    poll: () => client.poll(request.requestId),
    interval: pollInterval,
    maxInterval: pollMaxInterval,
    timeout: pollTimeout,
    sleep: sleep,
    isActive: isActive,
  );

  switch (polled) {
    case MagicLinkPollState.expired:
      await store.consume();
      return '登录链接已过期，请重新发起';
    case MagicLinkPollState.pending:
      // 超时或被取消：都按「没等到」处理。
      await store.consume();
      return isActive != null && !isActive() ? '已取消邮箱登录' : '等待确认超时，请重新发起';
    case MagicLinkPollState.confirmed:
      break;
  }

  final String code;
  try {
    code = await client.exchange(
      requestId: request.requestId,
      pkce: pkce,
      state: state,
    );
  } on AuthError catch (e) {
    await store.consume();
    return e.message;
  } catch (e) {
    await store.consume();
    return '授权码兑换失败：$e';
  }

  // 落盘点与深链回调/小程序共用：换 token、写安全存储、推进认证状态都在那里。
  return onCode(code, pkce);
}

/// 轮询确认状态，带退避、总超时与取消。
///
/// 退避把 10 分钟窗口内的请求数从 ~300 降到 ~80；总超时保证用户走开后
/// 登录页不会永远停在等待态（比报错更糟）。
Future<MagicLinkPollState> _pollMagicLink({
  required Future<MagicLinkPollState> Function() poll,
  required Duration interval,
  required Duration maxInterval,
  required Duration timeout,
  required Future<void> Function(Duration)? sleep,
  required bool Function()? isActive,
}) async {
  final wait = sleep ?? (d) => Future<void>.delayed(d);
  final deadline = DateTime.now().add(timeout);
  var delay = interval;

  while (DateTime.now().isBefore(deadline)) {
    if (isActive != null && !isActive()) return MagicLinkPollState.pending;
    final state = await poll();
    if (state != MagicLinkPollState.pending) return state;
    if (!DateTime.now().add(delay).isBefore(deadline)) break;
    await wait(delay);
    final next = delay * 1.5;
    delay = next > maxInterval ? maxInterval : next;
  }
  return MagicLinkPollState.pending;
}

/// 默认 `state` 生成（32 字符）。
///
/// 与 app 装配层的 `defaultAuthState` 同形态：两条登录路径的 state 不该有
/// 长度/字符集差异，否则排查 CSRF 类问题时还要分别确认。
String _defaultState() {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 32; i++) {
    buf.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return buf.toString();
}
