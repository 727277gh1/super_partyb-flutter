import 'dart:async';
import 'dart:math';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

/// 微信小程序登录编排（移动端唤起 / 桌面端手输码）：轮询确认 → 兑换授权码 → 落盘。
///
/// ## 为什么放在 spb_features 而不是某个 app
///
/// 移动端（唤起小程序）与桌面端（PC 显示 6 位码、手机输码）**只有「怎么把
/// scene 送到用户眼前」不同**，从「等确认」往后完全一致。放共享包是为了让
/// 「兑换时少传 pkce」这类错误不会只修在一条路径上。
///
/// app 只注入平台能力（[launch] / [launchViaSdk] / [onShortCode]）与落盘点。
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
/// ## 第三条通道：6 位短码（id-provider#18）
///
/// 两条唤起通道都可能**在运行时**不可用：OpenSDK 未编译进包（`85407`/未配置）、
/// 或 scheme 生成被微信拒绝（个人主体小程序）。此时不再直接失败，而是改成
/// 「App 展示 6 位码 → 用户自己打开小程序输入 → 回到 App 已登录」：
/// 零资质、零费用，也不需要任何微信「打开能力」。
///
/// 短码会话与扫码会话共用同一套轮询与兑换（`scene` 语义一致），所以这里只是
/// 换一个 scene 来源，后续流程一行不改。
///
/// 返回错误文案（null = 成功）。
Future<String?> miniProgramSignIn({
  required MiniProgramLoginClient client,
  required PendingAuthRequestStore store,
  // 用系统浏览器/scheme 唤起微信。null = 本平台没有这条通道（桌面端），
  // 此时直接走短码，不浪费一次注定失败的微信 API 调用。
  Future<bool> Function(Uri url)? launch,
  required Future<String?> Function(String code, PkcePair pkce) onCode,
  // OpenSDK 唤起（null = 不可用，退回 URL Scheme）。
  Future<String?> Function(String scene)? launchViaSdk,
  // 短码回退：拿到 6 位码后由 UI 展示给用户（null = 不支持，保持旧的失败行为）。
  void Function(MiniProgramShortCode code)? onShortCode,
  String Function()? stateGenerator,
  PkcePair Function()? pkceGenerator,
  Duration pollInterval = const Duration(seconds: 1),
  Duration pollMaxInterval = const Duration(seconds: 5),
  Duration pollTimeout = const Duration(minutes: 3),
  Future<void> Function(Duration)? sleep,
}) async {
  final state = (stateGenerator ?? _defaultAuthState)();
  final pkce = (pkceGenerator ?? OidcPkce.generatePair)();

  // 与浏览器流程一致：先把 state+verifier 落盘再发起。
  // 兑换时用的是内存里的 pkce，落盘是为了「应用被系统回收后仍能完成回调」
  // 这一场景的一致性——三条路径的失败语义保持一致，排查时不必区分。
  // （落盘必须在下面任何分支之前：落盘点 `onCode` 会读它校验 state。）
  await store.put(PendingAuthRequest(state: state, pkce: pkce));

  // 平台完全唤不起微信（桌面端没有小程序可唤起）：直接发短码。
  // Why 不是「先建 scheme 会话再失败」：`generatescheme` 对个人主体返回 85407，
  // 每次点击白花一次微信 API 配额，还多等一个网络往返。
  if (launch == null && launchViaSdk == null) {
    final start = await _startShortCode(
      client: client,
      store: store,
      onShortCode: onShortCode,
      originalError: '当前平台无法唤起微信小程序',
    );
    if (start.error != null) return start.error;
    SpbLog.info('已创建登录码等待手输确认', {'scene': start.scene});
    return _awaitAndExchange(
      client: client,
      store: store,
      scene: start.scene!,
      state: state,
      pkce: pkce,
      onCode: onCode,
      pollInterval: pollInterval,
      pollMaxInterval: pollMaxInterval,
      pollTimeout: pollTimeout,
      sleep: sleep,
    );
  }

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

  // 各通道最终使用的 scene（短码回退会换掉它）。
  var scene = session.scene;
  // 唤起通道运行期不可用时的原因；非空则改走短码。
  String? fallbackReason;

  if (useSdk) {
    String? sdkError;
    try {
      sdkError = await launchViaSdk(session.scene);
    } catch (e) {
      SpbLog.warn('OpenSDK 唤起小程序异常', {'error': e.toString()});
      sdkError = '无法唤起微信小程序：$e';
    }
    if (sdkError != null) {
      // 运行期才失败（未配置 / 85407 / 微信未安装）：不再让用户卡在错误上，
      // 改走短码。SDK 调用失败不消耗任何服务端状态，换一个码是安全的。
      SpbLog.warn('OpenSDK 唤起失败，尝试改用短码', {'error': sdkError});
      fallbackReason = sdkError;
    }
  } else if (!session.canLaunchWeChat) {
    // scheme 生成失败 = 个人主体小程序拿不到权限（85412）。短码是唯一剩下的通道。
    fallbackReason = session.schemeError ?? '当前环境无法直接唤起微信，请改用其他登录方式';
  } else {
    try {
      // 走到这里 launch 一定非空（launch 与 launchViaSdk 都为 null 时已在
      // 函数开头直接走短码）。
      final ok = await launch!(Uri.parse(session.schemeUrl!));
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

  if (fallbackReason != null) {
    final fallback = await _startShortCode(
      client: client,
      store: store,
      onShortCode: onShortCode,
      originalError: fallbackReason,
    );
    if (fallback.error != null) return fallback.error;
    scene = fallback.scene!;
    SpbLog.info('已改为短码确认', {'scene': scene});
  } else {
    SpbLog.info('已唤起微信小程序等待确认', {'scene': scene});
  }

  return _awaitAndExchange(
    client: client,
    store: store,
    scene: scene,
    state: state,
    pkce: pkce,
    onCode: onCode,
    pollInterval: pollInterval,
    pollMaxInterval: pollMaxInterval,
    pollTimeout: pollTimeout,
    sleep: sleep,
  );
}

/// 轮询确认 → 兑换授权码 → 交给落盘点（三条通道共用）。
///
/// 抽出来的原因：扫码/唤起/短码的差别**只在 scene 怎么来**，从「等确认」
/// 往后一模一样。复制三段会让「兑换时少传 pkce」这类错误只在某一条路径上出现。
Future<String?> _awaitAndExchange({
  required MiniProgramLoginClient client,
  required PendingAuthRequestStore store,
  required String scene,
  required String state,
  required PkcePair pkce,
  required Future<String?> Function(String code, PkcePair pkce) onCode,
  required Duration pollInterval,
  required Duration pollMaxInterval,
  required Duration pollTimeout,
  Future<void> Function(Duration)? sleep,
}) async {
  final polled = await pollMiniProgramSession(
    poll: () => client.poll(scene),
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
    code = await client.exchange(scene: scene, pkce: pkce, state: state);
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

/// 短码回退的结果：要么拿到新 scene，要么带着「该显示给用户的错误」返回。
class _ShortCodeStart {
  const _ShortCodeStart({this.scene, this.error});
  final String? scene;
  final String? error;
}

/// 发起短码会话并把码交给 UI 展示。
///
/// 调用方已经落盘了 state/pkce（短码与扫码共用同一个待完成请求），所以这里
/// 失败必须 `store.consume()`——否则下次启动会带着一个永远不会完成的请求。
Future<_ShortCodeStart> _startShortCode({
  required MiniProgramLoginClient client,
  required PendingAuthRequestStore store,
  required void Function(MiniProgramShortCode code)? onShortCode,
  required String originalError,
}) async {
  if (onShortCode == null) {
    // 没有 UI 承接展示：保持旧行为（返回原始错误），不要让用户看到
    // 「正在等待确认」却根本没有任何码可看。
    await store.consume();
    return _ShortCodeStart(error: originalError);
  }
  try {
    final session = await client.createShortCodeSession();
    final shortCode = session.shortCode;
    if (shortCode == null) {
      await store.consume();
      return const _ShortCodeStart(error: '登录码创建失败，请重试');
    }
    onShortCode(shortCode);
    return _ShortCodeStart(scene: session.scene);
  } on AuthError catch (e) {
    await store.consume();
    return _ShortCodeStart(error: e.message);
  } catch (e) {
    await store.consume();
    SpbLog.warn('创建短码会话失败', {'error': e.toString()});
    return _ShortCodeStart(error: '无法创建登录码：$e');
  }
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

/// 默认 `state` 生成（32 字符）。
///
/// 与 `magic_link_signin.dart` / app 装配层的生成器同形态：几条登录路径的
/// state 不该有长度或字符集差异，否则排查 CSRF 类问题时要分别确认。
String _defaultAuthState() {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 32; i++) {
    buf.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return buf.toString();
}
