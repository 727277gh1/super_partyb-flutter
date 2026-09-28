import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spb_core/spb_core.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'providers.dart';

/// 桌面端入口。
///
/// 初始化顺序（有依赖关系，不可调换）：
/// 1. `WidgetsFlutterBinding` —— 插件调用前必须先初始化绑定；
/// 2. 日志 sink；
/// 3. 桌面能力（窗口/托盘/快捷键）—— 依赖绑定已就绪；
/// 4. 依赖注入容器（ProviderScope overrides）；
/// 5. `runApp`。
Future<void> main() async {
  // ensureInitialized 的静态返回类型是 WidgetsBinding，实际实例是
  // WidgetsFlutterBinding（平台实现）。bootstrapDesktop 需要后者的具体类型
  // 以便访问平台通道，故显式转型。
  final binding =
      WidgetsFlutterBinding.ensureInitialized() as WidgetsFlutterBinding;

  SpbLog.configure(
    sink: const ConsoleLogSink(),
    minLevel: SpbEnv.verboseLogging ? LogLevel.debug : LogLevel.info,
  );
  SpbLog.info('启动 Super PartyB 桌面端', {
    'env': SpbEnv.environment,
    'api': SpbEnv.apiBaseUrl,
    'release': SpbEnv.isRelease,
  });

  // 桌面能力初始化必须在 runApp 之前：托盘与窗口需在首帧前就绪，
  // 否则启动瞬间会闪现默认窗口尺寸再跳到配置尺寸。
  final capabilities = await bootstrapDesktop(binding);

  runApp(
    ProviderScope(
      overrides: [desktopCapabilitiesProvider.overrideWithValue(capabilities)],
      child: const SpbDesktopApp(),
    ),
  );
}
