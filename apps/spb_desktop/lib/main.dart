import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart' show clearDataUrlImageMemo;
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
///
/// ## 日志去向（控制台 + 本地文件）
///
/// 进程从桌面启动器/双击拉起时 stdout **无处可去**，而「导出诊断日志」需要
/// 应用还活着、用户能进设置页。故除控制台外再追加一份文件日志
/// （[FileLogSink]，路径见 [defaultLogFilePath]）。
///
/// 同时写一对会话标记（[logSessionStartMessage] / [logSessionCleanExitMessage]）：
/// 下次启动时若日志末尾没有正常退出标记，就说明上次是崩溃 / 被杀 / 掉电
/// ——在「崩溃上报」有意不做（AGENTS.md §6.20 第 2 层）的前提下，这是能区分
/// 「崩了」与「被关了」的最低成本手段。
void main() {
  installGlobalErrorHandlers(() async {
    // ensureInitialized 的静态返回类型是 WidgetsBinding，实际实例是
    // WidgetsFlutterBinding（平台实现）。bootstrapDesktop 需要后者的具体类型
    // 以便访问平台通道，故显式转型。
    final binding =
        WidgetsFlutterBinding.ensureInitialized() as WidgetsFlutterBinding;

    _configureLogging();
    SpbLog.info('启动 Super PartyB 桌面端', {
      'env': SpbEnv.environment,
      // 读解析后的基地址：启动探测可能已升级到 IPv6 源站域名。
      'api': SpbEndpoints.current.apiBaseUrl,
      'release': SpbEnv.isRelease,
    });

    // 全局 imageCache 显式上限（docs/memory-audit.md G4b）。默认的框架上限
    // 偏大且按张数淘汰；显式收紧到字节驱动后，几张预览大图不会驻留几十 MB
    // 解码位图。必须在 ensureInitialized 之后（本函数已在其中）。
    configureImageCache();

    // 内存采样（docs/memory-audit.md §四）：进程 RSS / OS 高水位 / imageCache
    // 占用按分钟进一个有界环形缓冲，随「导出诊断日志」交给用户报障。这是
    // 本仓库唯一能在无 DISPLAY 的开发机之外拿到**真实内存曲线**的通道
    // （DevTools 需 profile 模式与环境，用户机器上没有）。
    //
    // 必须在 configureImageCache 之后：首条采样就是基线，缓存配置之前采到
    // 的 imageCache 值没有参照意义。
    installMemoryProbe();

    // 内存高水位日志：越过阈值时**低频**写一条，带 MemoryLedger 的内存分解
    // （时间线 / 缩略图 / 气泡缓存 / 交付物清单）。采样器只记曲线不落日志，
    // 而用户只在出问题时才导出报告——这条通道负责「没导出时也留下证据」。
    // 桌面端**不自动清缓存**：没有 OS 低内存信号可作依据，且在拿到真实机器的
    // 分解数据前，自动清理只是在拿界面抖动赌收益（见 memory_watchdog.dart）。
    installMemoryWatchdog();

    // 同步链路的在途字节也进账本（`sync_memory.dart`）：下载/上传会把整份文件
    // 读进内存，而这条路径**没有页面级持有方**，2026-11 真机报障里高水位日志
    // 的 `breakdown=` 因此是空的（只有 imageCache 0.3MB，看不出 400MB 去哪了）。
    // 进程级登记、与进程同寿命，故不注销。
    registerSyncInFlightGauge();

    // 系统内存压力信号（docs/memory-audit.md G9）：桌面端引擎不派发这条信号
    // （Linux/Windows/macOS 无此系统回调），注册后零效果、无副作用——两端
    // 无差别接线，将来若引擎补齐也无需改这里。
    installMemoryPressureHandler(
      onRelease: () {
        clearDataUrlImageMemo();
        // 压力时刻的值最值得留一笔：它往往就是峰值。
        installedMemoryProbe?.sample(force: true);
        SpbLog.info('系统内存压力：已清空图片解码缓存');
      },
    );

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
    //
    // 远端会话探测（issue #110）也在这里并发：结果写进 `SpbDisplayEnv` 的
    // 进程级缓存（诊断报告要同步读它，而首帧的动效策略也要它），且它是
    // 一次平台通道往返（微秒级）。**必须**在 `runApp` 之前完成，否则首帧会
    // 按「本地会话」的策略渲染，随后再降级一次——那次降级本身就是一次
    // 整窗重绘，恰好是这条改动要避免的事情。
    final results = await Future.wait<Object?>([
      bootstrapDesktop(binding),
      resolveEndpointsAtStartup(),
      SpbDisplayEnv.detectRemoteSession(),
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
        // 清单在 `providers.dart` 的 `buildProductionOverrides`（**唯一**来源）：
        // 写在这里的 override 没有任何测试能看见，漏挂一条就是静默失效——
        // 通知 sink 就这样丢过一次（见 `production_overrides_test.dart`）。
        overrides: buildProductionOverrides(capabilities: capabilities),
        child: const SpbDesktopApp(),
      ),
    );
  });
}

/// 装配日志 sink：控制台 + **本地文件**（后者是「进程死了就没证据」的补偿）。
///
/// ## 为什么要先读上次会话状态，再写启动标记
///
/// 顺序写反就永远等于「上次正常退出」：先写 [logSessionStartMessage] 会把
/// 「日志最后一行」变成启动标记，于是 [previousSessionExitedCleanly] 永远
/// 只能看到它、看不到上一次会话的退出标记。故：
///
/// 1. 读（上次最后一行是干净的退出标记吗？）；
/// 2. 装 sink；
/// 3. 写启动标记（并把上一轮的结论一并记下）；
/// 4. 若上一轮不干净，补一条 `warn`（不带它，用户永远不会知道）。
///
/// ## 为什么文件日志不可用时只降级、不抛
///
/// 日志是旁路：磁盘满 / 目录只读 / 沙箱拒绝都不能让应用起不来。
/// `FileLogSink` 自身在首次写入失败后会停用（不重试刷屏），这里补一条
/// `warn` 把原因留在控制台上；用户报障时我们仍能从会话标记看出「日志不全」。
void _configureLogging() {
  const minLevel = SpbEnv.verboseLogging ? LogLevel.debug : LogLevel.info;
  final path = defaultLogFilePath();
  if (path == null) {
    // 拿不到 HOME / APPDATA：只输出到控制台（与既有行为一致）。
    SpbLog.configure(sink: const ConsoleLogSink(), minLevel: minLevel);
    return;
  }

  final previousClean = previousSessionExitedCleanly(path);
  final fileSink = FileLogSink(path: path);
  SpbLog.configure(
    sink: MultiLogSink([const ConsoleLogSink(), fileSink]),
    minLevel: minLevel,
  );

  SpbLog.info(logSessionStartMessage, {
    'log': path,
    // null = 首次运行 / 刚轮转（不可判为异常，见函数文档）。
    'previous_clean': previousClean ?? '(未知)',
  });

  if (previousClean == false) {
    SpbLog.warn('上次会话未正常退出（无退出标记：崩溃 / 被结束进程 / 掉电）', {'log': path});
  }
  if (fileSink.isDisabled) {
    SpbLog.warn('本地文件日志不可写，仅输出到控制台', {
      'log': path,
      'error': '${fileSink.lastError}',
    });
  }
}
