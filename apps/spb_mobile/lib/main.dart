import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart' show clearDataUrlImageMemo;
import 'package:spb_platform/spb_platform.dart';

import 'app.dart';
import 'providers.dart';

/// 移动端入口。
///
/// 初始化顺序（有依赖关系，不可调换）：
/// 1. `installGlobalErrorHandlers` —— 全局错误兜底（issue #45）；
/// 2. `WidgetsFlutterBinding` —— 插件调用前必须先初始化绑定；
/// 3. 日志 sink；
/// 4. 依赖注入容器（`ProviderScope`）；
/// 5. 深链监听（认证回调）**与端点探测并发**；
/// 6. `runApp`。
///
/// ## 为什么错误兜底必须是第一步
///
/// 它要捕获的是「初始化自身抛出的异常」——若晚于 `SpbLog.configure`，则在
/// 那之前的异常会落到默认 sink（且不进环形缓冲，见 AGENTS.md §6.20 的「阈值
/// 过滤在记录之前」）。而 `SpbLog` 默认就是 `ConsoleLogSink` + info 级，
/// 故错误不会被丢弃。
///
/// ## 为什么深链监听要放在 `runApp` 之前
///
/// 冷启动场景下，把应用拉起的那个链接必须在**首帧之前**被处理：
/// 否则用户会先看到登录页（因为此时还没有会话），然后才被回调推进到已登录，
/// 中间闪一下。这里**有意 `await`** [AuthDeepLinkReceiver.start]：它内部会先
/// 取一次 `getInitialLink()`（平台通道往返，毫秒级），代价远小于一次登录页闪烁。
void main() {
  installGlobalErrorHandlers(() async {
    WidgetsFlutterBinding.ensureInitialized();

    SpbLog.configure(
      sink: const ConsoleLogSink(),
      minLevel: SpbEnv.verboseLogging ? LogLevel.debug : LogLevel.info,
    );
    SpbLog.info('启动 Super PartyB 移动端', {
      'env': SpbEnv.environment,
      // 读解析后的基地址：启动探测可能已升级到 IPv6 源站域名。
      'api': SpbEndpoints.current.apiBaseUrl,
    });

    // 全局 imageCache 显式上限（docs/memory-audit.md G4b）：移动端内存更
    // 紧张，显式收紧到字节驱动。必须在 ensureInitialized 之后。
    configureImageCache();

    // 内存采样（docs/memory-audit.md §四）：进程 RSS / OS 高水位 / imageCache
    // 占用按分钟进一个有界环形缓冲，随「导出诊断日志」交给用户报障。
    // 移动端的内存最紧张，而这正是之前完全没有数据的一维。
    //
    // 必须在 configureImageCache 之后：首条采样就是基线。
    installMemoryProbe();

    // 内存高水位日志（带 MemoryLedger 分解）。移动端另有内存压力信号会清
    // imageCache（见下），但压力信号只在真正吃紧时来；高水位日志记录的是
    // 「离上限还有多远」以及**谁占的**（时间线 / 缩略图 / 气泡缓存 / 清单）。
    installMemoryWatchdog();

    // 同步链路的在途字节也进账本（`sync_memory.dart`）：下载/上传会把整份文件
    // 读进内存，而这条路径**没有页面级持有方**（账本只在会话页/交付面板
    // 登记），于是高水位日志的 `breakdown=` 会是空的。进程级登记、与进程同寿命。
    registerSyncInFlightGauge();

    // 系统内存压力信号（docs/memory-audit.md G9）：Android/iOS 引擎在内存
    // 吃紧时派发 `memoryPressure`，此前全仓无接收方。收到后清空全局解码缓存
    // （可再生：下次显示时重解码，不丢任何数据）。
    //
    // 为什么不在这里传页面级缓存的清理：`_bubbleCache` / `_thumbnailMemo`
    // 是对话页 State 的私有字段，跨层清空需要新管路；两者合计只有 KB~MB
    // 级，而 imageCache 是最大头的可再生态（单张大图可达几十 MB）。
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

    // override 清单在 `providers.dart` 的 `buildProductionOverrides`（**唯一**
    // 来源）：本项目此前从未在这里挂过通知 sink，导致生产一直跑 Noop 实现、
    // 通知功能静默失效。
    final container = ProviderContainer(overrides: buildProductionOverrides());
    // 监听自定义 scheme 回跳（`partyb://oidc/callback`），把授权码交给
    // OIDC 客户端换取会话。见 `auth_deeplink.dart`。
    //
    // 它与端点探测**并发**：两者互不依赖，串行会把探测的耗时（无 IPv6 时
    // ~10ms，黑洞场景最多 1.5s）叠加到启动延迟上。
    //
    // 注：`UncontrolledProviderScope` 是必需的——`SpbMobileApp` 是
    // `ConsumerStatefulWidget`，没有容器时会在 build 时抛异常。
    final results = await Future.wait<Object?>([
      container.read(authDeepLinkReceiverProvider).start(),
      resolveEndpointsAtStartup(),
    ]);
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
      UncontrolledProviderScope(
        container: container,
        child: const SpbMobileApp(),
      ),
    );
  });
}
