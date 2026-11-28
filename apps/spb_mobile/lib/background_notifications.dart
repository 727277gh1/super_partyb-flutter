import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';
import 'package:workmanager/workmanager.dart';

const notificationPollingTask = 'spb.notices.poll.v1';

/// 旧任务名（轮询确认卡列表），只用于升级时显式取消。
///
/// 必须显式取消：WorkManager 的周期任务按 unique name 注册，改名不会自动清掉
/// 旧的那个，两个并存就会各自唤醒、各自弹一条。
const legacyNotificationPollingTask = 'spb.confirmations.poll.v1';
const notificationPollingInterval = Duration(minutes: 15);

NotificationStateStore openNotificationState() => NotificationStateStore.open(
  () async => File(
    p.join((await getApplicationSupportDirectory()).path, 'notifications.db'),
  ),
);

TokenStore createNotificationTokenStore(
  NotificationStateStore state,
  LocalNotificationSink sink,
) => CoordinatedTokenStore(
  tokens: SecureTokenStore(cacheEnabled: false),
  state: state,
  cancelNotification: sink.cancel,
);

class WorkmanagerNotificationScheduler implements NotificationPollingScheduler {
  WorkmanagerNotificationScheduler({Workmanager? workmanager, bool? supported})
    : _workmanager = workmanager ?? Workmanager(),
      supported = supported ?? supportsBackgroundNotifications;
  final Workmanager _workmanager;
  Future<void>? _initializing;

  @override
  final bool supported;

  @override
  Future<void> reconcile({required bool enabled}) async {
    if (!supported) return;
    // 旧任务名无论开关都清掉（幂等）：升级后第一次 reconcile 就完成迁移。
    await _workmanager.cancelByUniqueName(legacyNotificationPollingTask);
    if (!enabled) {
      await _workmanager.cancelByUniqueName(notificationPollingTask);
      return;
    }
    try {
      await (_initializing ??= _workmanager.initialize(
        notificationCallbackDispatcher,
      ));
    } catch (error) {
      // 失败不得永久缓存：用户可能刚给了自启动/后台权限，回前台要能重试。
      _initializing = null;
      SpbLog.warn('WorkManager 初始化失败', {'error': error.toString()});
      rethrow;
    }
    await _workmanager.registerPeriodicTask(
      notificationPollingTask,
      notificationPollingTask,
      frequency: notificationPollingInterval,
      initialDelay: notificationPollingInterval,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 1),
    );
  }
}

@pragma('vm:entry-point')
void notificationCallbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  BackgroundNotificationWorker? active;
  Workmanager().executeTask(
    (task, inputData) async {
      if (task != notificationPollingTask) return true;
      final worker = active = BackgroundNotificationWorker();
      try {
        return await worker.run();
      } finally {
        active = null;
      }
    },
    onTaskStopped: (task, reason) async {
      active?.stop();
    },
  );
}

/// 只装配 HTTP、Keystore、通知和持久化记录，不启动 UI、SSE 或其他队列。
class BackgroundNotificationWorker {
  BackgroundNotificationWorker({
    this.openState = openNotificationState,
    LocalNotificationSink? sink,
    this.createTokens = createNotificationTokenStore,
    this.isForeground = NotificationForegroundBridge.isForeground,
    this.resolveEndpoints = resolveEndpointsAtStartup,
    this.apiClient,
  }) : _sink = sink ?? LocalNotificationSink();

  final NotificationStateStore Function() openState;
  final LocalNotificationSink _sink;
  final TokenStore Function(NotificationStateStore, LocalNotificationSink)
  createTokens;
  final Future<bool> Function() isForeground;
  final Future<SpbEndpoints> Function() resolveEndpoints;
  final Dio? apiClient;
  Dio? _apiDio;
  Dio? _oidcDio;
  bool _stopped = false;

  void stop() {
    _stopped = true;
    _apiDio?.close(force: true);
    _oidcDio?.close(force: true);
  }

  Future<bool> run() async {
    final state = openState();
    final sink = _sink;
    final tokens = createTokens(state, sink);
    final deadline = Timer(const Duration(minutes: 2), stop);
    try {
      if (await isForeground()) {
        return await _skip(state, BackgroundCheckSkip.foreground);
      }
      if (!await sink.hasPermission()) {
        return await _skip(state, BackgroundCheckSkip.noPermission);
      }
      final generation = await state.exclusive(() async {
        if (await tokens.read() == null) return null;
        return state.generation();
      });
      if (generation == null) {
        return await _skip(state, BackgroundCheckSkip.loggedOut);
      }

      final endpoints = await resolveEndpoints();
      if (_stopped) return await _skip(state, BackgroundCheckSkip.interrupted);
      final oidcDio = _oidcDio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 15),
          // 令牌刷新同样只由后台这一轮发起，带同一标记便于在 IdP 侧对账。
          headers: {'User-Agent': kBackgroundPollUserAgent},
        ),
      );
      final oidc = OidcClient(config: OidcConfig.fromEnv(), dio: oidcDio);
      final manager = SessionManager(
        store: tokens,
        refresher: (current) async => StoredTokens.fromOidcTokens(
          await oidc.refresh(refreshToken: current.refreshToken!),
        ),
      );
      final auth = AuthInterceptor(
        tokenProvider: manager.currentAccessToken,
        onUnauthorizedOutcome: manager.refreshWithOutcome,
      );
      final dio = _apiDio =
          apiClient ??
          createDio(
            baseUrl: endpoints.apiBaseUrl,
            receiveTimeout: const Duration(seconds: 30),
            interceptors: [auth],
            userAgent: kBackgroundPollUserAgent,
          );
      // 注入的 client（测试 / 未来换实现）也要带同一个标记：否则「后台那一轮
      // 到没到服务端」在日志里又变得不可判定。
      dio.options.headers['User-Agent'] = kBackgroundPollUserAgent;
      if (apiClient != null) dio.interceptors.insert(0, auth);
      auth.replayDio = dio;
      // 数据源是 /me/notices（持久事实），不是 /chat/confirmations（卡片）。
      // 卡片 10 分钟后过期并消失，而 15 分钟周期必然拉到过期卡——旧实现因此
      // 每轮都白跑。notice 不会消失，15 分钟延迟就变成可接受的通知延迟。
      final api = NoticesApi(dio);
      // 数量不变也可能更新内容；包含已读通知才能撤销别端已读的横幅。
      final page = await api.list(limit: 200);
      if (_stopped) return await _skip(state, BackgroundCheckSkip.interrupted);
      return await state.exclusive(() async {
        // 网络请求期间可能登出或换账号，旧响应不得发到新会话。
        if (generation != await state.generation() ||
            await tokens.read() == null) {
          return await _skip(state, BackgroundCheckSkip.sessionChanged);
        }
        if (_stopped || await isForeground()) {
          return await _skip(state, BackgroundCheckSkip.foreground);
        }
        final inbox = ConfirmationNotificationInbox(
          store: state,
          show: (notification) async {
            if (_stopped || await isForeground()) {
              return false;
            }
            return sink.showChecked(notification);
          },
          cancel: sink.cancel,
          canNotify: sink.hasPermission,
        );
        // complete 恒为 false：拉的是有上限的一页，不能据「缺席」推断已处理。
        // 撤销靠 notice 的 read_at（已读即 resolved），不靠缺席。
        final sent = await inbox.handleNotices(page.notices, focused: false);
        // 成功也写：读数要能回答「这一次跑成功了吗」，不能只有失败才留痕。
        await _record(
          state,
          BackgroundCheckResult(
            outcome: BackgroundCheckOutcome.ok,
            at: DateTime.now(),
            unread: page.unread,
            fetched: page.notices.length,
            shown: sent.length,
          ),
        );
        SpbLog.info('后台通知检查完成', {
          'unread': page.unread,
          'fetched': page.notices.length,
          'shown': sent.length,
        });
        return true;
      });
    } on AuthError catch (error) {
      // 后台不清除凭证、不跳登录；再次登录后任务仍可继续。
      SpbLog.warn('后台通知暂时无法认证', {'error': error.message});
      await _record(
        state,
        BackgroundCheckResult(
          outcome: BackgroundCheckOutcome.failed,
          at: DateTime.now(),
          failure: BackgroundCheckFailure.auth,
          error: error.message,
        ),
      );
      return true;
    } catch (error) {
      SpbLog.warn('后台通知检查失败，将退避重试', {'error': error.toString()});
      await _record(
        state,
        BackgroundCheckResult(
          outcome: BackgroundCheckOutcome.failed,
          at: DateTime.now(),
          failure: BackgroundCheckFailure.request,
          error: error.toString(),
        ),
      );
      return false;
    } finally {
      deadline.cancel();
      stop();
      await state.close();
    }
  }

  /// 记一条「有意不发」并返回「本轮算成功」（不触发退避重试）。
  Future<bool> _skip(
    NotificationStateStore state,
    BackgroundCheckSkip skip,
  ) async {
    await _record(
      state,
      BackgroundCheckResult(
        outcome: BackgroundCheckOutcome.skipped,
        at: DateTime.now(),
        skip: skip,
      ),
    );
    return true;
  }

  /// 落盘失败只记日志：诊断读数写不进去，绝不能连累「这一轮发不发通知」。
  Future<void> _record(
    NotificationStateStore state,
    BackgroundCheckResult result,
  ) async {
    try {
      await state.recordBackgroundCheck(result);
    } on Object catch (error) {
      SpbLog.warn('后台检查结果落盘失败', {'error': error.toString()});
    }
  }
}
