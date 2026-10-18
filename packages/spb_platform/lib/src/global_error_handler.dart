import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:spb_core/spb_core.dart';

/// 安装全局错误兜底，让未捕获异常进入 [SpbLog] 环形缓冲（issue #45）。
///
/// ## 它解决什么问题
///
/// issue #40 已实现「导出诊断日志」（环形缓冲 + 环境信息 + 脱敏），但它的
/// **输入只有显式走 `SpbLog` 的日志**。异常若没被 `try/catch` 包住，就进不了
/// 环形缓冲——用户导出的报告里**不会有它**。诊断通道建好了，却没有接上
/// 「异常」这个最主要的诊断来源。
///
/// 而 release 构建下未捕获的异步异常是**静默丢弃**的（Flutter 默认只在 debug
/// 打印），于是「应用莫名其妙没反应」这种最需要诊断的场景恰好没有任何记录。
///
/// ## 三道防线（缺一不可，覆盖不同的异常来源）
///
/// | 来源 | 钩子 |
/// |---|---|
/// | Flutter 框架（build/layout/paint 抛出的） | [FlutterError.onError] |
/// | 平台/引擎层的异步异常（`Future` 未 await 的拒绝等） | [PlatformDispatcher.onError] |
/// | 当前 Zone 里的同步/异步异常（含 `main` 自身抛出的） | [runZonedGuarded] |
///
/// ⚠️ **三者不重叠**：[FlutterError.onError] 只管框架内的，
/// [PlatformDispatcher.onError] 管引擎投递上来的，`runZonedGuarded` 管「在它这个
/// Zone 里创建的所有异步操作」。只装一个会漏掉另外两类——例如只装
/// `FlutterError.onError` 就抓不到
/// `Future.delayed(...).then((_) => throw ...)`。
///
/// ## 为什么要保留 `FlutterError.presentError`
///
/// debug 下的红色错误屏幕是开发体验的核心。若把它替换掉（而不是**追加**），
/// 开发时异常会变得不可见——这是「为了线上诊断而牺牲开发效率」的坏交易。
/// 故 [installFlutterErrorHandler] 先调 [FlutterError.presentError]（保留默认
/// 行为），再记日志。
///
/// ## 用法
///
/// 在 `main()` 的最开头调用（早于任何可能抛异常的初始化），并把剩余初始化
/// 放进 [body]：
///
/// ```dart
/// void main() {
///   installGlobalErrorHandlers(() async {
///     WidgetsFlutterBinding.ensureInitialized();
///     ... 现有初始化 ...
///   });
/// }
/// ```
///
/// ## 为什么返回 `void` 而不是 `Future<void>`
///
/// [runZonedGuarded] 的签名就是 `void`（它不 await body）。`main` 里若写成
/// `Future<void> main() async` 再 `await` 它，反而会引入「body 的异常已被 Zone
/// 捕获、但外层 Future 也已失败」的双重报告。故与 Flutter 官方示例一致：
/// 同步调用，不 await。
///
/// ## 为什么放在 `spb_platform` 而不是 `spb_core`
///
/// [FlutterError] / [PlatformDispatcher] 来自 `package:flutter/foundation.dart`，
/// 而 `spb_core` 是**纯 Dart 包**（禁止 import Flutter，AGENTS.md §4 由
/// `tools/check_layering.sh` 强制）。本包已是 Flutter 包，且两端 app 都依赖它。
void installGlobalErrorHandlers(Future<void> Function() body) {
  installFlutterErrorHandler();
  installPlatformErrorHandler();
  runZonedGuarded(() => unawaited(body()), (error, stack) {
    SpbLog.error('Zone 未捕获异常', error: error, stackTrace: stack);
  });
}

/// 安装 [FlutterError.onError]（框架异常）。
///
/// 单独导出是为了**可测**：测试可以 save / restore 全局钩子，无需启动整个
/// `installGlobalErrorHandlers`（那会创建 Zone，断言困难）。
void installFlutterErrorHandler() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    // 保留默认行为（debug 下红色屏幕）。若上一个 handler 存在，也交给它。
    FlutterError.presentError(details);
    previous?.call(details);
    SpbLog.error(
      'Flutter 框架异常',
      error: details.exception,
      stackTrace: details.stack,
      fields: {
        if (details.library != null) 'library': details.library,
        'silent': details.silent,
      },
    );
  };
}

/// 安装 [PlatformDispatcher.onError]（平台/引擎层异步异常）。
///
/// 单独导出理由同 [installFlutterErrorHandler]。
///
/// 返回 `true` 表示「已处理」——阻止引擎把它当致命错误。若不返回 true，
/// 某些平台会直接终止进程。
void installPlatformErrorHandler() {
  final previous = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    SpbLog.error('未捕获的异步异常', error: error, stackTrace: stack);
    return previous?.call(error, stack) ?? true;
  };
}
