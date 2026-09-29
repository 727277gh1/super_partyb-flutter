import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spb_core/spb_core.dart';

import 'app.dart';
import 'providers.dart';

/// 移动端入口。
///
/// 初始化顺序（有依赖关系，不可调换）：
/// 1. `WidgetsFlutterBinding` —— 插件调用前必须先初始化绑定；
/// 2. 日志 sink；
/// 3. 依赖注入容器（`ProviderScope`）；
/// 4. 深链监听（认证回调）；
/// 5. `runApp`。
///
/// ## 为什么深链监听要放在 `runApp` 之前
///
/// 冷启动场景下，把应用拉起的那个链接必须在**首帧之前**被处理：
/// 否则用户会先看到登录页（因为此时还没有会话），然后才被回调推进到已登录，
/// 中间闪一下。这里**有意 `await`** [AuthDeepLinkReceiver.start]：它内部会先
/// 取一次 `getInitialLink()`（平台通道往返，毫秒级），代价远小于一次登录页闪烁。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SpbLog.configure(
    sink: const ConsoleLogSink(),
    minLevel: SpbEnv.verboseLogging ? LogLevel.debug : LogLevel.info,
  );
  SpbLog.info('启动 Super PartyB 移动端', {
    'env': SpbEnv.environment,
    'api': SpbEnv.apiBaseUrl,
  });

  final container = ProviderContainer();
  // 监听自定义 scheme 回跳（`partyb://oidc/callback`），把授权码交给
  // OIDC 客户端换取会话。见 `auth_deeplink.dart`。
  //
  // 注：`ProviderScope` 是必需的——`SpbMobileApp` 是
  // `ConsumerStatefulWidget`，没有容器时会在 build 时抛异常。
  await container.read(authDeepLinkReceiverProvider).start();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SpbMobileApp(),
    ),
  );
}
