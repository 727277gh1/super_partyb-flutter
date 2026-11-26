import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_mobile/background_notifications.dart';
import 'package:spb_platform/spb_platform.dart';
import 'package:workmanager/workmanager.dart';

class _Sink extends LocalNotificationSink {
  bool permitted = true;
  final shown = <LocalNotification>[];
  @override
  Future<bool> hasPermission() async => permitted;
  @override
  Future<bool> showChecked(LocalNotification notification) async {
    shown.add(notification);
    return true;
  }

  @override
  Future<void> cancel(String id) async {}
}

class _WorkmanagerPlatform extends WorkmanagerPlatform {
  int initializations = 0;
  int cancellations = 0;
  final registrations =
      <
        ({
          String name,
          Duration? frequency,
          ExistingPeriodicWorkPolicy? policy,
          NetworkType? network,
        })
      >[];
  @override
  Future<void> initialize(
    Function callbackDispatcher, {
    bool isInDebugMode = false,
  }) async {
    initializations++;
  }

  final cancelledNames = <String>[];

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    // 只允许两个名字：当前任务名，以及改名前的旧任务名。旧任务必须被显式取消
    // ——WorkManager 按 unique name 注册，改名不会自动清掉旧的，两个并存就会
    // 各自唤醒、各自弹一条。
    expect(
      uniqueName,
      anyOf(notificationPollingTask, legacyNotificationPollingTask),
    );
    cancelledNames.add(uniqueName);
    cancellations++;
  }

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    ForegroundServiceConfig? foregroundServiceConfig,
  }) async {
    expect(inputData, isNull, reason: '任务参数不得持久化 token');
    expect(taskName, notificationPollingTask);
    registrations.add((
      name: uniqueName,
      frequency: frequency,
      policy: existingWorkPolicy,
      network: constraints?.networkType,
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('每 15 分钟联网执行，重复协调保留周期，未登录取消', () async {
    final manager = Workmanager();
    final previous = WorkmanagerPlatform.instance;
    final platform = _WorkmanagerPlatform();
    WorkmanagerPlatform.instance = platform;
    addTearDown(() => WorkmanagerPlatform.instance = previous);
    final scheduler = WorkmanagerNotificationScheduler(
      workmanager: manager,
      supported: true,
    );
    await scheduler.reconcile(enabled: true);
    await scheduler.reconcile(enabled: true);
    await scheduler.reconcile(enabled: false);
    expect(platform.initializations, 1);
    expect(platform.registrations, hasLength(2));
    expect(platform.registrations.first.frequency, const Duration(minutes: 15));
    expect(
      platform.registrations.first.policy,
      ExistingPeriodicWorkPolicy.keep,
    );
    expect(platform.registrations.first.network, NetworkType.connected);
    // 每次 reconcile 都幂等清一次旧任务名（3 次），关闭时再清当前任务名（1 次）。
    expect(platform.cancellations, 4);
    expect(
      platform.cancelledNames.where((n) => n == legacyNotificationPollingTask),
      hasLength(3),
    );
    expect(
      platform.cancelledNames.where((n) => n == notificationPollingTask),
      hasLength(1),
    );
  });

  group('后台 Worker 使用真实 API 适配和通知判定', () {
    late Directory directory;
    late NotificationStateStore state;
    late InMemoryTokenStore tokens;
    late _Sink sink;
    late Dio dio;
    late DioAdapter adapter;
    late bool foreground;
    late int endpointCalls;
    File file() => File('${directory.path}/state.db');

    /// 直接建同步连接（不走 `NotificationStateStore.open` 的
    /// `createInBackground`）：同一进程里同时开多个后台 isolate 连接会让 drift
    /// 在测试环境下报「Channel was closed」，而这里要的只是「同一文件多个连接」。
    NotificationStateStore openStore() =>
        NotificationStateStore(AppDatabase(NativeDatabase(file())));

    /// worker 的 finally 会 close 掉它自己那份 store（后台 isolate 每轮自开库），
    /// 故回读一律另开一个连接——这也顺带验证了「读数确实落了盘」。
    Future<BackgroundCheckReport> report() async {
      final reader = openStore();
      try {
        return await reader.backgroundCheckReport();
      } finally {
        await reader.close();
      }
    }

    tearDown(() async {
      await state.close();
      await directory.delete(recursive: true);
    });
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('spb-bg-notify-');
      state = openStore();
      await state.generation();
      tokens = InMemoryTokenStore();
      await tokens.write(const StoredTokens(accessToken: 'test-token'));
      sink = _Sink();
      foreground = false;
      endpointCalls = 0;
      dio = createDio(baseUrl: 'https://example.invalid/pba');
      adapter = DioAdapter(dio: dio);
    });
    BackgroundNotificationWorker worker() => BackgroundNotificationWorker(
      openState: openStore,
      sink: sink,
      apiClient: dio,
      createTokens: (_, _) => tokens,
      isForeground: () async => foreground,
      resolveEndpoints: () async {
        endpointCalls++;
        return SpbEndpoints.current;
      },
    );
    Map<String, dynamic> notice() => {
      'id': 'n1',
      'kind': 'confirmation_required',
      'severity': 'warning',
      'title': '需要你确认',
      'body': '需要确认是否继续重试',
      'data': {
        'confirmation_id': 'c1',
        'expires_at': DateTime.now()
            .add(const Duration(minutes: 10))
            .toIso8601String(),
      },
      'group_id': 'g1',
      'created_at': DateTime.now().toIso8601String(),
    };
    void stubUnread(int count) => adapter.onGet(
      '/me/notices/unread-count',
      (s) => s.reply(200, {'unread': count}),
    );
    void stubList(List<Map<String, dynamic>> items) => adapter.onGet(
      '/me/notices',
      (s) => s.reply(200, {'notices': items, 'unread': items.length}),
      queryParameters: {'limit': 200},
    );

    test('真实列表响应发出通知且带对话路由', () async {
      stubUnread(1);
      stubList([notice()]);
      expect(await worker().run(), isTrue);
      expect(sink.shown.single.payload, '/chat/g1');
      expect(sink.shown.single.title, '需要你确认');
      // 成功也要留读数：否则设置页只能回答「跑过没有」，答不了「这次跑成没有」。
      final after = await report();
      expect(after.last!.outcome, BackgroundCheckOutcome.ok);
      expect(after.last!.fetched, 1);
      expect(after.last!.shown, 1);
      expect(after.lastSuccessAt, isNotNull);
    });

    test('每种「有意不发」都留下可读的成因（否则用户只能猜）', () async {
      // 前台
      foreground = true;
      expect(await worker().run(), isTrue);
      expect((await report()).last!.skip, BackgroundCheckSkip.foreground);
      foreground = false;

      // 没权限
      sink.permitted = false;
      expect(await worker().run(), isTrue);
      expect((await report()).last!.skip, BackgroundCheckSkip.noPermission);
      sink.permitted = true;

      // 未登录
      await tokens.clear();
      expect(await worker().run(), isTrue);
      final loggedOut = await report();
      expect(loggedOut.last!.skip, BackgroundCheckSkip.loggedOut);
      // 跳过不写「上次成功」：那个时刻只代表真的成功过。
      expect(loggedOut.lastSuccessAt, isNull);
    });
    test('后台请求带 spb-bg 标记，服务端日志才能把这一轮与前台轮询分开', () async {
      // 前台 15 秒轮询与后台 worker 打的是同一个路径、同一个 API；唯一能区分的
      // 就是 UA。它只用于观测，不得作为鉴权依据（见 kBackgroundPollUserAgent）。
      final userAgents = <String?>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            userAgents.add(options.headers['User-Agent'] as String?);
            handler.next(options);
          },
        ),
      );
      stubUnread(0);
      stubList([]);
      expect(await worker().run(), isTrue);
      expect(userAgents, contains(kBackgroundPollUserAgent));
    });

    test('没有未读也拉取已读事实以撤销陈旧通知', () async {
      stubUnread(0);
      stubList([]);
      expect(await worker().run(), isTrue);
      expect(sink.shown, isEmpty);
    });
    test('前台不探测端点、不请求网络、不通知', () async {
      foreground = true;
      expect(await worker().run(), isTrue);
      expect(endpointCalls, 0);
      expect(sink.shown, isEmpty);
    });
    test('通知权限拒绝不请求网络', () async {
      sink.permitted = false;
      expect(await worker().run(), isTrue);
      expect(endpointCalls, 0);
    });
    test('登出后旧任务唤醒也不请求网络', () async {
      await tokens.clear();
      expect(await worker().run(), isTrue);
      expect(endpointCalls, 0);
    });
    test('HTTP 503 返回 retry，保留凭证', () async {
      adapter.onGet(
        '/me/notices',
        (s) => s.reply(503, <String, dynamic>{}),
        queryParameters: {'limit': 200},
      );
      expect(await worker().run(), isFalse);
      expect(await tokens.read(), isNotNull);
      expect(sink.shown, isEmpty);
      // 失败要留痕：这是「退避重试」与「压根没跑」的唯一区分点。
      final failed = await report();
      expect(failed.last!.outcome, BackgroundCheckOutcome.failed);
      expect(failed.last!.failure, BackgroundCheckFailure.request);
      expect(failed.last!.error, isNotNull);
    });
    test('网络等待期间换账号，旧响应不能发通知', () async {
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) async {
            if (response.requestOptions.path.endsWith('/me/notices')) {
              await state.exclusive(state.advanceSession);
            }
            handler.next(response);
          },
        ),
      );
      stubUnread(1);
      stubList([notice()]);
      expect(await worker().run(), isTrue);
      expect(sink.shown, isEmpty);
      expect((await report()).last!.skip, BackgroundCheckSkip.sessionChanged);
    });
    test('网络等待期间回到前台，不补弹通知', () async {
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            foreground = true;
            handler.next(response);
          },
        ),
      );
      stubUnread(1);
      stubList([notice()]);
      expect(await worker().run(), isTrue);
      expect(sink.shown, isEmpty);
    });
  });
}
