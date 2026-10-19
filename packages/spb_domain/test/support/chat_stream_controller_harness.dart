/// `ChatStreamController` 契约测试的共享夹具（issue #48 从
/// `chat_stream_controller_test.dart` 抽出）。
///
/// ## 为什么是「顶层变量 + setUpHarness()」而不是一个类
///
/// 原文件的测试体直接写 `api.xxx` / `sse.push(...)` / `sseEvent(...)`。
/// 抽成类（`harness.api.xxx`）要改**每一处**调用点——那就不是「纯移动」了。
/// 顶层 `late` 变量 + 在 `main()` 开头调一次 [setUpHarness]，则调用点
/// **逐字不变**。
///
/// ⚠️ 每个测试文件各自 `import` 并调 `setUpHarness()`（Dart 的测试隔离
/// 以**文件**为界，故跨文件共享顶层变量安全）。
///
/// ⚠️ `FakeTimelineCache` / `FakeOutboxStore` / `queueFor` 原本是文件私有的
/// `_Xxx`——移到共享夹具后必须去掉下划线（跨库不可见），故拆分时这几处
/// 调用点同步改名（纯重命名，无行为变化）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 假的 [SseClient]。
///
/// ## 为什么用「继承真类 + 覆盖全部公开成员」而不是 implements
///
/// [SseClient] 不是接口，`ChatStreamController` 依赖具体类型。用 `implements`
/// 需要实现全部公开成员（含 `recordEventId`/`lastEventId`/`state` 等），编译器会
/// 逐个报缺；这里用 `extends` + `super(dio: ..., baseUrl: ...)`，只覆盖控制器
/// 真正会调用的那几个，其余保持真实实现（不连网络，因为从不调 connect）。
///
/// 好处：`ChatStreamController` 里对 `_sse.recordEventId(...)` 的调用被真实记录，
/// 于是「transient 事件不得推进游标」这条不变式可以被断言。
class FakeSseClient extends SseClient {
  FakeSseClient()
    : super(dio: Dio(), baseUrl: 'https://fake.invalid', maxRetries: 0);

  final framesController = StreamController<SseFrame>.broadcast();
  final statesController = StreamController<SseState>.broadcast();

  /// 被推进的游标序列（按调用顺序）。
  final recordedEventIds = <String>[];

  /// `connect` 被调用的次数与路径。
  final connectedPaths = <String>[];

  int resumeCount = 0;
  bool disposed = false;

  /// 当前游标（模拟 `SseClient._lastEventId`）。
  ///
  /// 真实 `connect()` 会把它置 null（断线重连的游标清零语义），此处必须同构：
  /// 否则「切 group 不得重连」这条不变式在假实现上无从观测。
  @override
  String? lastEventId;

  @override
  Stream<SseFrame> get frames => framesController.stream;

  @override
  Stream<SseState> get states => statesController.stream;

  @override
  SseState get state => SseState.connected;

  /// 推一个连接状态（测「SSE 恢复 → 触发离线队列重试」）。
  void emitState(SseState s) => statesController.add(s);

  @override
  Future<void> connect({required String path}) async {
    connectedPaths.add(path);
    // 同真实实现：connect 重置续接游标。
    lastEventId = null;
  }

  @override
  Future<void> resume() async {
    resumeCount++;
  }

  @override
  void recordEventId(String eventId) {
    recordedEventIds.add(eventId);
    lastEventId = eventId;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await framesController.close();
    await statesController.close();
  }

  /// 推一帧到控制器。
  void push(String event, Map<String, dynamic> data) {
    framesController.add(SseFrame(event: event, data: _encode(data), id: null));
  }

  /// 推心跳注释帧。
  void pushHeartbeat() {
    framesController.add(const SseFrame(event: null, data: '', id: null));
  }

  static String _encode(Map<String, dynamic> m) {
    // SseClient 的 data 是 JSON 字符串；控制器自行 jsonDecode。
    final sb = StringBuffer('{');
    var first = true;
    for (final e in m.entries) {
      if (!first) sb.write(',');
      first = false;
      sb.write('"${e.key}":${_json(e.value)}');
    }
    sb.write('}');
    return sb.toString();
  }

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
/// ## 为什么要一个假实现而不是用 drift 内存库
///
/// `spb_domain` **禁止依赖 `spb_data`**（AGENTS.md §3 的分层规则），故本层
/// 测试不能用 `DriftTimelineCacheStore`。契约本身是纯 Dart 的，用内存 Map
/// 实现即可——这正是把契约放在 domain 的收益。
///
/// 实现真实存储的三层上限/过滤**不在这里**验证（那是 `spb_data` 的用例），

/// 这里只记录「谁在什么时候被读写」。
class FakeTimelineCache implements TimelineCacheStore {
  final Map<String, List<ChatEvent>> _data = {};

  /// 记录 `save` 的调用（group → 事件列表，按调用顺序累积）。
  final saved = <(String, List<ChatEvent>)>[];

  /// 被读取过的 group（按调用顺序）。
  final loadedGroups = <String>[];

  /// 被清空过的 group。
  final clearedGroups = <String>[];

  void seed(String groupId, List<ChatEvent> events) {
    _data[groupId] = List.of(events);
  }

  List<ChatEvent> eventsFor(String groupId) =>
      saved.where((r) => r.$1 == groupId).expand((r) => r.$2).toList();

  Set<String> get savedGroups => saved.map((r) => r.$1).toSet();

  @override
  Future<List<ChatEvent>> load(String groupId, {int? limit}) async {
    loadedGroups.add(groupId);
    final all = _data[groupId] ?? const <ChatEvent>[];
    if (limit == null || limit <= 0 || all.length <= limit) {
      return List.of(all);
    }
    return all.sublist(all.length - limit);
  }

  @override
  Future<void> save(String groupId, List<ChatEvent> events) async {
    saved.add((groupId, List.of(events)));
    // 真实实现是 upsert；这里只需让「后续 load」能拿到，故按 globalSeq 合并。
    final merged = <int, ChatEvent>{
      for (final e in _data[groupId] ?? const <ChatEvent>[]) e.globalSeq!: e,
      for (final e in events.where(isCacheableEvent)) e.globalSeq!: e,
    };
    _data[groupId] = merged.values.toList()
      ..sort((a, b) => a.globalSeq!.compareTo(b.globalSeq!));
  }

  @override
  Future<void> clear(String groupId) async {
    clearedGroups.add(groupId);
    _data.remove(groupId);
  }
}

/// 内存版 [OutboxStore]（本文件只验证接线，队列行为见 `outbox_test.dart`）。
class FakeOutboxStore implements OutboxStore {
  final Map<String, OutboxEntry> rows = {};

  @override
  Future<List<OutboxEntry>> load(String userId) async =>
      rows.values.where((e) => e.userId == userId).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> upsert(OutboxEntry entry) async => rows[entry.id] = entry;

  @override
  Future<void> delete(String id) async => rows.remove(id);

  @override
  Future<void> clear(String userId) async =>
      rows.removeWhere((_, e) => e.userId == userId);
}

/// 造一个队列。[fail] 为 null 时投递总是成功（返回固定的 `turn-out`），
/// 否则抛出它。
///
/// ## 为什么要能造「投递也失败」的队列
///
/// `ChatStreamController.send` 遇到可重试错误会**把消息交给队列**，而队列自己
/// 会立刻试一次——若队列的 `send` 成功，`send` 返回的是投递结果（不是
/// `MessageQueuedError`）。要验证「真的排上了」，队列的投递必须也失败。
OutboxQueue queueFor(FakeOutboxStore store, {SpbError? fail}) => OutboxQueue(
  store: store,
  send: (e) async {
    if (fail != null) throw fail;
    return SendMessageResult(
      turnId: 'turn-out',
      groupId: e.groupId ?? 'grp_1',
      status: 'queued',
      requestId: e.id,
    );
  },
  // 抖动关闭：退避时长确定，测试不 flaky。
  policy: const OutboxRetryPolicy(jitterRatio: 0, maxAttempts: 1),
);

/// 共享的 `Dio` / `DioAdapter` / `ChatApi` / `FakeSseClient`。
///
/// 测试体里直接写 `api.xxx` / `sse.push(...)`（与原文件一致）；
/// `main()` 开头调一次 [setUpHarness] 即可。
late Dio dio;
late DioAdapter adapter;
late ChatApi api;
late FakeSseClient sse;

/// 在 `main()` 开头调用一次。
void setUpHarness() {
  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    sse = FakeSseClient();
  });
}

/// 造一个服务端形态的 SSE 事件 JSON（camelCase，同 chatbus.Event）。
Map<String, dynamic> sseEvent(
  String type, {
  String id = 'evt_1',
  String turnId = 'turn_1',
  String groupId = 'grp_1',
  Map<String, dynamic>? payload,
  bool transient = false,
  int seq = 1,
  int globalSeq = 1,
}) => {
  'eventId': id,
  'userId': 'usr_1',
  'groupId': groupId,
  'turnId': turnId,
  'eventType': type,
  'seq': seq,
  'globalSeq': globalSeq,
  'source': 'test',
  'payload': payload,
  'createdAt': '2024-03-05T08:09:10Z',
  if (transient) 'transient': true,
};

/// 挂载 timeline 回填的 mock（控制器 start/switchGroup 会先拉 timeline）。
void mockTimeline({List<Map<String, dynamic>>? events}) {
  adapter.onGet(
    '/chat/groups/grp_1/timeline',
    (server) => server.reply(200, {
      'items': events ?? <Map<String, dynamic>>[],
      'next_before_global_seq': '',
    }),
    queryParameters: {'limit': 200},
  );
}

/// 挂载 sendMessage 的 mock。
///
/// `data: Matchers.any` 必需：http_mock_adapter 的默认匹配器会连**请求体**一起
/// 比对，不声明 `data` 等于断言「请求体为 null」，于是真实 POST 永远匹配不上
/// （表现为 NetworkError: 未知网络错误：null）。请求体形状的断言属 spb_api 层，
/// 此处只关心控制器的状态变化。
void mockSendMessage({String turnId = 'turn_1', String groupId = 'grp_1'}) {
  adapter.onPost(
    '/users/usr_1/chat/messages',
    (server) => server.reply(201, {
      'turn_id': turnId,
      'group_id': groupId,
      'status': 'queued',
    }),
    data: Matchers.any,
  );
}
