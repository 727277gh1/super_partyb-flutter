import 'dart:async';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

import 'auth_deeplink.dart';

/// App 内「微信一键登录」：唤起小程序 → 轮询确认 → 兑换授权码 → 落盘。
///
/// ## 为什么 App 里要另开一条路
///
/// 现有两条路在手机上都别扭：
/// - 系统浏览器 SSO：至少 3 次跳转，且在浏览器里登录完还要等深链回跳；
/// - 微信扫码：**同机无法扫码**（用户只有这一台手机）。
///
/// 这条路的前提是用户装了微信（没装则唤起失败，降级回 SSO），换来的是
/// 「点一下 → 在微信里确认 → 直接进首页」。
///
/// ## 职责边界
///
/// - 本函数**只做编排**：发会话、唤起、轮询、兑换、交给 [onCode] 落盘；
/// - 不发 token 请求（[onCode] 内部用 `OidcClient.exchangeCode` 换 token），
///   这样移动端所有登录路径共用同一个落盘点；
/// - 不导航（由路由守卫根据认证状态决定）。
///
/// ## 两条唤起通道
///
/// 1. **OpenSDK**（[launchViaSdk]，`WXLaunchMiniProgram`）：微信服务端方案对
///    个人主体小程序不可用（`85407`），客户端 SDK 调用不受该限制，是当前唯一
///    能真正唤起小程序的通道；
/// 2. **URL Scheme**（[launch] + `session.schemeUrl`）：非个人主体小程序可用。
///
/// 有 OpenSDK 时**不再请求 schemeUrl**：那是注定失败的一次微信 API 调用
/// （多耗配额、多一次等待），且失败时返回的 `schemeError` 会把真正可用的
/// 通道挡在前面。
///
/// 返回错误文案（null = 成功）。
Future<String?> miniProgramSignIn({
  required MiniProgramLoginClient client,
  required PendingAuthRequestStore store,
  required Future<bool> Function(Uri url) launch,
  required Future<String?> Function(String code, PkcePair pkce) onCode,
  // OpenSDK 唤起（null = 不可用，退回 URL Scheme）。
  Future<String?> Function(String scene)? launchViaSdk,
  String Function()? stateGenerator,
  PkcePair Function()? pkceGenerator,
  Duration pollInterval = const Duration(seconds: 1),
  Duration pollMaxInterval = const Duration(seconds: 5),
  Duration pollTimeout = const Duration(minutes: 3),
  Future<void> Function(Duration)? sleep,
}) async {
  final state = (stateGenerator ?? defaultAuthState)();
  final pkce = (pkceGenerator ?? OidcPkce.generatePair)();

  // 与浏览器流程一致：先把 state+verifier 落盘再发起。
  // 兑换时用的是内存里的 pkce，落盘是为了「应用被系统回收后仍能完成回调」
  // 这一场景的一致性——两条路径的失败语义保持一致，排查时不必区分。
  await store.put(PendingAuthRequest(state: state, pkce: pkce));

  // 有 OpenSDK 就不要 schemeUrl（见函数文档）。
  final useSdk = launchViaSdk != null;

  final MiniProgramSession session;
  try {
    session = await client.createSession(withScheme: !useSdk);
  } on AuthError catch (e) {
    await store.consume();
    return e.message;
  } catch (e) {
    await store.consume();
    return '无法创建微信登录会话：$e';
  }

  if (useSdk) {
    String? sdkError;
    try {
      sdkError = await launchViaSdk(session.scene);
    } catch (e) {
      SpbLog.warn('OpenSDK 唤起小程序异常', {'error': e.toString()});
      sdkError = '无法唤起微信小程序：$e';
    }
    if (sdkError != null) {
      await store.consume();
      return sdkError;
    }
  } else {
    if (!session.canLaunchWeChat) {
      await store.consume();
      return session.schemeError ?? '当前环境无法直接唤起微信，请改用其他登录方式';
    }

    try {
      final ok = await launch(Uri.parse(session.schemeUrl!));
      if (!ok) {
        await store.consume();
        return '无法唤起微信，请确认已安装微信后重试';
      }
    } catch (e) {
      await store.consume();
      SpbLog.warn('唤起微信失败', {'error': e.toString()});
      return '无法唤起微信，请确认已安装微信后重试';
    }
  }

  SpbLog.info('已唤起微信小程序等待确认', {'scene': session.scene});

  final polled = await pollMiniProgramSession(
    poll: () => client.poll(session.scene),
    interval: pollInterval,
    maxInterval: pollMaxInterval,
    timeout: pollTimeout,
    sleep: sleep,
  );

  if (polled == MiniProgramPollState.expired) {
    await store.consume();
    return '登录已超时，请重新发起';
  }
  if (polled != MiniProgramPollState.done) {
    await store.consume();
    return '等待微信确认超时，请重试';
  }

  final String code;
  try {
    code = await client.exchange(
      scene: session.scene,
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

  // 落盘点与深链回调共用（`oidcCallbackHandlerProvider`）：
  // 换 token、写安全存储、推进认证状态都在那里，两条路径行为一致。
  return onCode(code, pkce);
}

/// 轮询扫码状态，带退避与总超时。
///
/// ## 为什么要退避
///
/// 固定 1 秒轮询在用户慢慢确认时会产生上百次请求（服务端是内存 map，但没必要）。
/// 退避到 [maxInterval] 后，3 分钟窗口内的请求数从 ~180 降到 ~50。
///
/// ## 为什么必须有总超时
///
/// 用户唤起微信后可能直接退出去了。没有超时，这个 Future 会一直挂着，
/// 登录页的「正在等待确认」状态就永远不结束——比报错更糟。
Future<MiniProgramPollState> pollMiniProgramSession({
  required Future<MiniProgramPollState> Function() poll,
  Duration interval = const Duration(seconds: 1),
  Duration maxInterval = const Duration(seconds: 5),
  Duration timeout = const Duration(minutes: 3),
  Future<void> Function(Duration)? sleep,
}) async {
  final wait = sleep ?? (d) => Future<void>.delayed(d);
  final deadline = DateTime.now().add(timeout);
  var delay = interval;

  while (DateTime.now().isBefore(deadline)) {
    final state = await poll();
    if (state != MiniProgramPollState.pending) return state;
    if (!DateTime.now().add(delay).isBefore(deadline)) break;
    await wait(delay);
    final next = delay * 1.5;
    delay = next > maxInterval ? maxInterval : next;
  }
  return MiniProgramPollState.pending;
}
