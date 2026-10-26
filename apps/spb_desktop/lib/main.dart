import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'providers.dart';

/// 桌面端入口。
///
/// 初始化顺序（有依赖关系，不可调换）：
/// 1. `installGlobalErrorHandlers` —— 全局错误兜底（issue #45）；
/// 2. `WidgetsFlutterBinding` —— 插件调用前必须先初始化绑定；
/// 3. 日志 sink；
/// 4. 桌面能力（窗口/托盘/快捷键）**与端点探测并发** —— 前者依赖绑定已就绪，
///    后者只读编译期常量 + 一次 TCP 探测，两者无依赖；
/// 5. 依赖注入容器（ProviderScope overrides）；
/// 6. `runApp`。
///
/// ## 为什么错误兜底必须是第一步
///
/// 它要捕获的是「初始化自身抛出的异常」——尤其是第 4 步的桌面能力初始化
/// （`window_manager` / `tray_manager` / `hotkey_manager` 都走平台通道，是
/// 最易在特定桌面环境下失败的一环，见 AGENTS.md §9）。
///
/// `installGlobalErrorHandlers` 内部装的是 [FlutterError.onError]、
/// [PlatformDispatcher.instance.onError] 与 `runZonedGuarded` 三道防线
/// （实现与理由见 `spb_platform/lib/src/global_error_handler.dart`）。
void main() {
  installGlobalErrorHandlers(() async {
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
      // 读解析后的基地址：启动探测可能已升级到 IPv6 源站域名。
      'api': SpbEndpoints.current.apiBaseUrl,
      'release': SpbEnv.isRelease,
    });

    // 帧耗时观测（可选，`--dart-define=SPB_FRAME_TIMING=true` 开启）。
    //
    // 放在 `SpbLog.configure` **之后**：上报器在帧回调里写 SpbLog，若在
    // configure 之前安装，首批日志会落到默认 sink 与默认级别，行为不一致。
    // 默认关闭时不注册回调，零开销。
    if (SpbEnv.frameTiming) installFrameTimingReporter();

    // 桌面能力初始化必须在 runApp 之前：托盘与窗口需在首帧前就绪，
    // 否则启动瞬间会闪现默认窗口尺寸再跳到配置尺寸。
    //
    // 端点探测与它**并发**：两者互不依赖，串行会把探测的耗时（无 IPv6 时
    // ~10ms，黑洞场景最多 1.5s）叠加到启动延迟上。
    final results = await Future.wait<Object?>([
      bootstrapDesktop(binding),
      resolveEndpointsAtStartup(),
    ]);
    final capabilities = results[0] as DesktopCapabilities;
    final endpoints = results[1] as SpbEndpoints;

    // 只记 host 名，不记完整 URL：日志会进「导出诊断日志」报告，
    // 而报告会被贴进公开 issue。
    SpbLog.info('服务端点已解析', {
      'chosenHost': endpoints.chosenHost ?? '(未配置)',
      'probeOutcome': endpoints.probeOutcome.name,
    });

    // 运行中端点切换要落一条日志（issue #50）：用户报「突然变慢/突然连不上」
    // 时，诊断报告里得能看出「当时降级了」。降级/升级本身的 warn/info 已由
    // `SpbEndpoints.downgrade` 与 `EndpointGuard.tryUpgrade` 记录，这里只补
    // 「切换后的基地址」这一条，避免重复刷屏。
    //
    // 订阅不取消是有意的：它是进程级监听，活到进程结束；`EndpointGuard` 的
    // 计时器在 App 退出时无需清理（进程退出即结束）。
    SpbEndpoints.changes.listen((next) {
      SpbLog.info('服务端点已切换', {
        'host': next.chosenHost ?? '(unknown)',
        'outcome': next.probeOutcome.name,
      });
    });

    runApp(
      ProviderScope(
        overrides: [
          desktopCapabilitiesProvider.overrideWithValue(capabilities),
          // 拖拽能力仅在桌面端真实可用：移动端保留 Provider 默认的
          // NoopDragDropCapability（见 providers.dart），UI 只需判 isSupported。
          dragDropCapabilityProvider.overrideWithValue(
            const DesktopDragDropCapability(),
          ),
        ],
        child: const SpbDesktopApp(),
      ),
    );
  });
}
