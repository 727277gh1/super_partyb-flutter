/// `ConversationPage` widget 测试的共享夹具（issue #48 从
/// `conversation_page_test.dart` 抽出，该文件原 3864 行）。
///
/// ## 为什么是「顶层变量 + setUpHarness()」而不是一个类
///
/// 原文件的测试体直接写 `controller = ...` / `pushEvent(tester, ...)` /
/// `sseEvent(...)`。抽成类（`h.api.xxx`）要改**每一处**调用点——那就不是
/// 「纯移动」了，diff 会混入数百处机械改写，审阅者无法分辨「搬家」与「真改动」。
/// 顶层 `late` 变量 + 在 `main()` 开头调一次 [setUpHarness] / [tearDownHarness]，
/// 则调用点**逐字不变**。
///
/// ⚠️ 每个拆分后的测试文件各自 `import` 并调用 [setUpHarness] /
/// [tearDownHarness]。Dart 的测试隔离以**文件**为界（`dart test` 每个文件
/// 独立 isolate），故跨文件共享顶层变量安全；同文件内 `setUp` 保证每条
/// 用例从干净状态开始。
///
/// ⚠️ `_FakeSseClient` / `_FakeTimelineCache` 原本是文件私有的 `_Xxx`——移到
/// 共享夹具后必须去掉下划线（跨库不可见），故拆分时引用它们的调用点同步改名
/// （纯重命名，无行为变化）。`controller` 被 4 处测试体重新赋值，顶层 `late`
/// 声明同样支持。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 假的 [SseClient]（与 spb_domain 的测试同构）。
class FakeSseClient extends SseClient {
  FakeSseClient()
    : super(dio: Dio(), baseUrl: 'https://fake.invalid', maxRetries: 0);

  final framesController = StreamController<SseFrame>.broadcast();
  final statesController = StreamController<SseState>.broadcast();

  @override
  Stream<SseFrame> get frames => framesController.stream;

  @override
  Stream<SseState> get states => statesController.stream;

  @override
  SseState get state => SseState.connected;

  @override
  Future<void> connect({required String path}) async {}

  @override
  Future<void> resume() async {}

  @override
  void recordEventId(String eventId) {}

  @override
  Future<void> dispose() async {
    await framesController.close();
    await statesController.close();
  }

  /// 推一帧（camelCase，同 chatbus.Event 的 SSE 形态）。
  void push(String event, Map<String, dynamic> data) {
    framesController.add(SseFrame(event: event, data: _encode(data), id: null));
  }

  static String _encode(Map<String, dynamic> m) =>
      const JsonEncoderShim().convert(m);
}

/// 极简 JSON 编码（避免引入 dart:convert 的 import 冲突）。
class JsonEncoderShim {
  const JsonEncoderShim();
  String convert(Object? v) => _json(v);
  static String _json(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return v.toString();
    if (v is String) {
      return '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
    }
    if (v is List) return '[${v.map(_json).join(',')}]';
    if (v is Map) {
      return '{${v.entries.map((e) => '"${e.key}":${_json(e.value)}').join(',')}}';
    }
    return '"$v"';
  }
}

/// 假的 [TimelineCacheStore]（issue #29）。
///
/// `spb_features` 不依赖 `spb_data`（分层：features 只经 apps 装配拿到实现），
/// 故这里用内存 Map 实现契约——正好也证明契约是纯 Dart 的。
class FakeTimelineCache implements TimelineCacheStore {
  FakeTimelineCache([List<ChatEvent>? seed]) {
    if (seed != null) _data['grp_1'] = List.of(seed);
  }

  final Map<String, List<ChatEvent>> _data = {};

  @override
  Future<List<ChatEvent>> load(String groupId, {int? limit}) async {
    final all = _data[groupId] ?? const <ChatEvent>[];
    return List.of(all);
  }

  @override
  Future<void> save(String groupId, List<ChatEvent> events) async {
    final merged = <int, ChatEvent>{
      for (final e in _data[groupId] ?? const <ChatEvent>[]) e.globalSeq!: e,
      for (final e in events.where(isCacheableEvent)) e.globalSeq!: e,
    };
    _data[groupId] = merged.values.toList()
      ..sort((a, b) => a.globalSeq!.compareTo(b.globalSeq!));
  }

  @override
  Future<void> clear(String groupId) async => _data.remove(groupId);
}

/// 共享的 `Dio` / `DioAdapter` / `ChatApi` / `FakeSseClient` / `ChatStreamController`。
late Dio dio;
late DioAdapter adapter;
late ChatApi api;
late FakeSseClient sse;
late ChatStreamController controller;

/// 超时兜底集合的推送通道（见原文件注释）。
late StreamController<Set<String>> staleController;

/// 在 `main()` 开头调用一次。
void setUpHarness() {
  setUp(() {
    staleController = StreamController<Set<String>>.broadcast();
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    sse = FakeSseClient();
    controller = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
  });
}

/// 在 `main()` 里 `setUpHarness()` 之后注册。
void tearDownHarness() {
  tearDown(() async {
    await staleController.close();
    await controller.dispose();
  });
}

/// 挂 timeline 回填的 mock。
void mockTimeline() {
  adapter.onGet(
    '/chat/groups/grp_1/timeline',
    (server) => server.reply(200, {
      'items': <Map<String, dynamic>>[],
      'next_before_global_seq': '',
    }),
    queryParameters: {'limit': 200},
  );
  // 控制器起连时会拉一次 turn 运行时参数（超时兜底阈值）。不挂这条 mock 也
  // 能跑（失败只记 warn 并退化为兜底值），但会在每个用例里刷一行 warning，
  // 掩盖真正的异常。
  adapter.onGet(
    '/api/chat/turn-runtime',
    (server) => server.reply(200, {
      'request_timeout_seconds': 300,
      'inactivity_timeout_seconds': 0,
      'client_turn_timeout_seconds': 300,
    }),
  );
}

/// 服务端形态的 SSE 事件 JSON。
Map<String, dynamic> sseEvent(
  String type, {
  required String id,
  String turnId = 'turn_1',
  Map<String, dynamic>? payload,
  bool transient = false,
  int seq = 1,
}) => {
  'eventId': id,
  'userId': 'usr_1',
  'groupId': 'grp_1',
  'turnId': turnId,
  'eventType': type,
  'seq': seq,
  'globalSeq': seq,
  'source': 'test',
  'payload': payload,
  'createdAt': '2024-03-05T08:09:10Z',
  if (transient) 'transient': true,
};

/// 启动控制器并完成 timeline 回填。
///
/// ⚠️ 必须包在 [WidgetTester.runAsync] 里：`testWidgets` 默认跑在 FakeAsync
/// 时区中，**真实 I/O（dio 的 HTTP 调用）永远不会完成**，`await start(...)`
/// 会挂死直到测试超时（表现为「did not complete」且耗时极长）。
/// `runAsync` 让回调跑在真实时区，dio 的 mock 响应才能 resolve。
Future<void> startController(WidgetTester tester) async {
  await tester.runAsync(() => controller.start(groupId: 'grp_1'));
}

/// 推一个 SSE 事件并等它被归约。
///
/// ⚠️ 必须在 [WidgetTester.runAsync] 内推：控制器的帧监听器是在
/// `startController` 的 runAsync 时区里注册的，在 FakeAsync 时区里 `add`
/// 的事件会被投递到另一个时区，`tester.pump()` 永远看不到它
/// （表现为「事件推了但列表是空的」）。
///
/// ## 为什么要在**真实时区**里多等（issue #44）
///
/// 归约现在被合并到一个零延迟 `Timer`（`_emit` → `flushEmit`）。而控制器的
/// 帧订阅是在 [startController] 的 `runAsync` 里注册的，故它触发的 `_emit`
/// 也落在**真实时区**——那里创建的 `Timer` 是真实计时器，`tester.pump()`
/// **永远跑不到它**（实测：`pump(5ms)` 也不触发，只有真实等待才行）。
///
/// 故必须在 `runAsync` 内等两个真实轮次：第一个让 SSE 帧投递到 `_onFrame`
/// 并排上归约计时器，第二个让该计时器真正执行并推送新 items。之后
/// `tester.pump()` 只是把已推送的状态渲染出来。
Future<void> pushEvent(
  WidgetTester tester,
  String type,
  Map<String, dynamic> data,
) async {
  await tester.runAsync(() async {
    sse.push(type, data);
    // 第 1 个轮次：帧 → `_onFrame` → `_emit`（排上归约计时器）。
    await Future<void>.delayed(Duration.zero);
    // 第 2 个轮次：归约计时器执行 → `items` 推送新列表。
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pump();
}

Future<void> pumpPage(
  WidgetTester tester, {
  String? title = '测试对话',
  void Function(String, String, String)? onResolveConfirmation,
  Future<void> Function(String token, bool correct)? onResolveFeedback,
  void Function(SpecUiAction action)? onSpecAction,
  void Function(String agentId)? onSelectAgent,
  void Function(HabitSuggestionItem suggestion)? onAcceptHabit,
  void Function(HabitSuggestionItem suggestion)? onDismissHabit,
  void Function(HabitSuggestionItem suggestion, HabitSnoozeOption option)?
  onSnoozeHabit,
  Future<void> Function(String)? onSend,
  Future<void> Function(String text, String? agentId)? onRetryTurn,
  bool enableSearch = false,
  Future<void> Function(String)? onCancelTurn,
  Future<List<int>?> Function(AgentFileItem file)? onLoadThumbnailAgentFile,
  Future<void> Function(AgentFileItem file)? onDownloadAgentFile,
  OpenAgentFile? onOpenAgentFile,
  RevealAgentFile? onRevealAgentFile,
  AgentFilePreviewCallbacks? onPreviewAgentFile,
  Future<bool> Function()? onLoadOlder,
  FlushPending? onFlush,
  FlushWithStrategy? onFlushWithStrategy,
  LoadPendingMessages? loadPending,
  UndoPendingMessage? undoPending,
  String? historyKey,
  VoidCallback? onReconnect,
  bool wireActivities = true,
  bool wireContextUsage = true,
  bool wireExecutionStatus = true,
  bool wireTtsStatus = true,
  bool wireStaleTurnIds = true,
  Set<String> staleTurnIds = const {},
  bool wireOutbox = false,
  List<OutboxEntry> outbox = const [],
  Stream<List<OutboxEntry>>? outboxStream,
  Future<bool> Function(String id)? onCancelOutbox,
  Future<bool> Function(String id)? onRetryOutbox,
  Future<void> Function(String id)? onRemoveOutbox,

  /// 注入归属反馈有效期（`ChatStreamController.attributionFeedbackTTL`）。
  ///
  /// 生产路径上它由控制器从 `GET /api/chat/turn-runtime` 拉取后持有；测试里
  /// 直接覆盖字段，避免为一条 TTL 断言造一个 HTTP mock（且 `turnRuntime()`
  /// 的响应还得过 DioAdapter）。
  ///
  /// null = 不覆盖（保持控制器已有值，通常是 null = 不做失效判定）。
  Duration? feedbackTTL,
}) async {
  if (feedbackTTL != null) {
    // `_attributionFeedbackTTL` 是私有的，但测试夹具在另一个库里——用
    // @visibleForTesting 的 setter 暴露。见 ChatStreamController.
    controller.debugSetAttributionFeedbackTTL(feedbackTTL);
  }
  await tester.pumpWidget(
    MaterialApp(
      home: ConversationPage(
        controller: controller,
        title: title,
        onResolveConfirmation: onResolveConfirmation,
        onResolveFeedback: onResolveFeedback,
        onAcceptHabit: onAcceptHabit,
        onDismissHabit: onDismissHabit,
        onSnoozeHabit: onSnoozeHabit,
        onSpecAction: onSpecAction,
        onSelectAgent: onSelectAgent,
        onSend: onSend,
        onRetryTurn: onRetryTurn,
        enableSearch: enableSearch,
        onCancelTurn: onCancelTurn,
        onLoadThumbnailAgentFile: onLoadThumbnailAgentFile,
        onDownloadAgentFile: onDownloadAgentFile,
        onOpenAgentFile: onOpenAgentFile,
        onRevealAgentFile: onRevealAgentFile,
        onPreviewAgentFile: onPreviewAgentFile,
        onLoadOlder: onLoadOlder,
        onFlush: onFlush,
        onFlushWithStrategy: onFlushWithStrategy,
        loadPending: loadPending,
        undoPending: undoPending,
        pendingReloadKey: historyKey,
        historyKey: historyKey,
        onReconnect: onReconnect,
        // 活动流由 app 层注入（与 onCancelTurn 等同取向）。默认接上
        // controller，便于测「事件到达 → 指示器出现」的完整链路；
        // wireActivities=false 用于验证「未注入时不展示」。
        activities: wireActivities ? controller.activities : null,
        activitiesSnapshot: wireActivities
            ? controller.activitiesSnapshot
            : null,
        // 上下文用量同理：默认接上，wireContextUsage=false 验证未注入时不展示。
        contextUsage: wireContextUsage ? controller.contextUsage : null,
        contextUsageSnapshot: wireContextUsage
            ? controller.contextUsageSnapshot
            : null,
        // 等待/重试状态同理。
        executionStatus: wireExecutionStatus
            ? controller.executionStatus
            : null,
        executionStatusSnapshot: wireExecutionStatus
            ? controller.executionStatusSnapshot
            : null,
        // 播报状态同理。
        ttsStatus: wireTtsStatus ? controller.ttsStatus : null,
        ttsStatusSnapshot: wireTtsStatus ? controller.ttsStatusSnapshot : null,
        // 超时兜底同理：默认接上 controller 的流，并用 staleTurnIds 注入
        // 初始集合（测试不必真等分钟级超时）。
        staleTurnIds: wireStaleTurnIds ? staleController.stream : null,
        staleTurnIdsSnapshot: wireStaleTurnIds ? staleTurnIds : null,
        // 离线队列（issue #30）：默认**不**接线（未注入时不展示任何东西），
        // 由各用例显式打开。
        outboxEntries: wireOutbox
            ? (outboxStream ?? const Stream.empty())
            : null,
        outboxSnapshot: wireOutbox ? outbox : null,
        onCancelOutbox: onCancelOutbox,
        onRetryOutbox: onRetryOutbox,
        onRemoveOutbox: onRemoveOutbox,
      ),
    ),
  );
  await tester.pump();
}

/// 把连接状态推成 [state]（控制器订阅 `sse.states` 后转发到自己的状态流）。
Future<void> pushConnectionState(WidgetTester tester, SseState state) async {
  await tester.runAsync(() async {
    sse.statesController.add(state);
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pump();
}

/// 直接替换页面 widget（保留 State），用于模拟「切 group」。
Future<void> rebuildPage(
  WidgetTester tester, {
  required Future<bool> Function() onLoadOlder,
  required String historyKey,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ConversationPage(
        controller: controller,
        title: '测试对话',
        onLoadOlder: onLoadOlder,
        historyKey: historyKey,
      ),
    ),
  );
  await tester.pump();
}

/// 推一个**流式中**的助手段落（增量帧 → `isStreaming: true`）。
///
/// 用 `transient: true`：服务端的流式增量就是这么发的（`llm_executor.go`
/// 的 delta 只广播不落库），而归约层据此置 `isStreaming`。
Future<void> pushStreamingMessage(
  WidgetTester tester, {
  String id = 'e_stream',
  String turnId = 'turn_1',
  String text = '正在生成',
  int seq = 1,
}) => pushEvent(
  tester,
  EventTypes.message,
  sseEvent(
    'message',
    id: id,
    turnId: turnId,
    payload: {'text': text},
    transient: true,
    seq: seq,
  ),
);
