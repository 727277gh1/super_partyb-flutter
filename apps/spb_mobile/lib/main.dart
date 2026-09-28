import 'package:flutter/material.dart';
import 'package:spb_core/spb_core.dart';

import 'app.dart';

/// 移动端入口。
///
/// 比桌面端简单：无托盘 / 多窗口 / 全局快捷键需要初始化。
/// 认证走系统浏览器 + 自定义 scheme 回跳（OIDC PKCE），
/// 而非桌面端的 loopback 重定向。
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

  runApp(const SpbMobileApp());
}
