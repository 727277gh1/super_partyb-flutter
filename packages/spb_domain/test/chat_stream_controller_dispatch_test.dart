import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// `dispatch_stage` → [ChatStreamController.dispatchProgress] 的接线
/// （issue #114 阶段 2 / super_partyb#181）。
///
/// ## 这组用例守的是什么
///
/// 分发帧是**首 token 之前**的旁路状态，它与现有四条旁路流（activities /
/// executionStatus / contextUsage / ttsStatus）有三个结构性差异，每个写错都
/// 不会抛异常，只会让进度条显示错的东西：
///
/// | 差异 | 写错的后果 |
/// |---|---|
/// | 没有 turn / group（发生在建 turn 之前） | 走通用路径进 [_buffer] → 归约 O(n) 空转、裁剪挤掉真历史 |
/// | Transient（不落库、不回放） | 推进游标 → 断线回放窗口整段丢失 |
/// | 归因只能靠 `request_id`（SSE 是 user 级订阅）| 显示**别的设备**正在做什么 |
///
/// 故这里逐条钉住：只认本端 rid、不进缓冲/游标、root 收尾即收起、请求返回后
/// 不再跟踪、切 group 清空、断线清空。
///
/// 共享夹具见 `support/chat_stream_controller_harness.dart`；「请求在飞」的
/// 时序由下面的 [_HangAdapter] 提供（`http_mock_adapter` 的 reply 是立即
/// 完成的，表达不出「POST 还没回来时帧已到达」）。
class _HangAdapter implements HttpClientAdapter {
  final _pending = <Completer<ResponseBody>>[];

  /// 等到 POST 真正到达适配器。
  ///
  /// dio 的拦截器链要走三个事件循环任务才调到 [fetch]，故必须轮询。
  Future<void> waitForRequest() async {
    for (var i = 0; i < 50 && _pending.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    if (_pending.isEmpty) throw StateError('请求未到达适配器（send 未发出？）');
  }

  void resolve(Map<String, dynamic> json, {int code = 201}) {
    _pending.removeLast().complete(
      ResponseBody.fromString(
        jsonEncode(json),
        code,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.method.toUpperCase() != 'POST') {
      return Future.value(
        ResponseBody.fromString(
          jsonEncode({'items': <dynamic>[], 'next_before_global_seq': ''}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
    }
    final c = Completer<ResponseBody>();
    _pending.add(c);
    return c.future;
  }

  @override
  void close({bool force = false}) {}
}

ChatStreamController _controllerWith(_HangAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test/pba'))
    ..httpClientAdapter = adapter;
  return ChatStreamController(sse: sse, api: ChatApi(dio), userId: 'usr_1');
}

/// 造一条服务端形状的 `dispatch_stage` 帧。
///
/// 与 Go 侧 `internal/dispatch/wire.go` 的 `StagePayload` / `RootPayload` 逐键
/// 对齐；`groupId` / `turnId` 都是空串——这正是分发帧的真实形态（发生在建
/// turn 之前）。
Map<String, dynamic> dispatchFrame({
  required String rid,
  required String name,
  String phase = 'start',
  int startMs = 0,
  int? endMs,
  int? budgetMs,
  String? status,
  String? reason,
  int? elapsedMs,
  int? unattributedMs,
  int? dropped,
}) => sseEvent(
  EventTypes.dispatchStage,
  id: 'evt_$name-$phase',
  turnId: '',
  groupId: '',
  transient: true,
  payload: {
    'phase': phase,
    'request_id': rid,
    'name': name,
    'start_ms': startMs,
    if (endMs != null) 'end_ms': endMs,
    if (budgetMs != null) 'budget_ms': budgetMs,
    if (status != null) 'status': status,
    if (reason != null) 'reason': reason,
    if (elapsedMs != null) 'elapsed_ms': elapsedMs,
    if (unattributedMs != null) 'unattributed_ms': unattributedMs,
    if (dropped != null) 'dropped': dropped,
  },
);

/// 让已推入的帧完成投递（broadcast 流是异步的，一拍不够）。
Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUpHarness();

  group('本端在飞的分发帧 → 进度快照', () {
    test('root start + 段 start 推出「当前在做什么」', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      final emitted = <DispatchStageProgress?>[];
      final sub = c.dispatchProgress.listen(emitted.add);

      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: dispatchRootStageName),
      );
      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(
          rid: 'rid_x',
          name: 'classify.llm',
          startMs: 5,
          budgetMs: 900,
        ),
      );
      await settle();

      final snapshot = c.dispatchProgressSnapshot;
      expect(snapshot, isNotNull, reason: '本端在飞的帧必须被归因');
      expect(snapshot!.currentStage, 'classify.llm');
      expect(snapshot.currentLabel, '正在判断消息归属');
      expect(snapshot.currentBudgetMs, 900);
      expect(snapshot.rootStarted, isTrue);
      expect(emitted.whereType<DispatchStageProgress>(), isNotEmpty);

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await sub.cancel();
      await c.dispose();
    });

    test('只有 root start 时也要出快照（最常见的形态）', () async {
      // 服务端先发 root start，再发各段。若「没有 currentStage 就推 null」，
      // 最常见的几百毫秒会是一条空白——那正是 #114 要消灭的空窗。
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(
          rid: 'rid_x',
          name: dispatchRootStageName,
          budgetMs: 4000,
        ),
      );
      await settle();

      expect(c.dispatchProgressSnapshot, isNotNull);
      expect(c.dispatchProgressSnapshot!.currentStage, isNull);
      expect(c.dispatchProgressSnapshot!.rootBudgetMs, 4000);
      // 文案退回 root（见 `dispatchProgressText`），不是空串。
      expect(dispatchProgressText(c.dispatchProgressSnapshot!), '正在分发');

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await c.dispose();
    });
  });

  group('归因：只认本端在飞的 rid', () {
    test('别的设备 / 小程序的分发帧一律不展示', () async {
      // SSE 是 user 级订阅：同一连接上会有别的设备、小程序 BFF、habit 续跑
      // 的分发帧。不按 rid 过滤的后果是**显示别人正在做什么**。
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      final emitted = <DispatchStageProgress?>[];
      final sub = c.dispatchProgress.listen(emitted.add);

      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_other_device', name: 'classify.prepare'),
      );
      await settle();

      expect(c.dispatchProgressSnapshot, isNull);
      expect(emitted, isEmpty);

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await sub.cancel();
      await c.dispose();
    });

    test('缺 request_id 的帧被丢弃（不可归因）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        sseEvent(
          EventTypes.dispatchStage,
          id: 'evt_no_rid',
          turnId: '',
          groupId: '',
          transient: true,
          payload: {'phase': 'start', 'name': 'enqueue', 'start_ms': 0},
        ),
      );
      await settle();

      expect(c.dispatchProgressSnapshot, isNull);

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await c.dispose();
    });
  });

  group('生命周期：什么时候收起', () {
    test('root 收尾帧到达即收起（turn 已建，等待交回轮次状态栏）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      final emitted = <DispatchStageProgress?>[];
      final sub = c.dispatchProgress.listen(emitted.add);

      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: dispatchRootStageName),
      );
      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: 'enqueue', startMs: 12),
      );
      await settle();
      expect(c.dispatchProgressSnapshot, isNotNull);

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(
          rid: 'rid_x',
          name: 'enqueue',
          phase: 'end',
          startMs: 12,
          endMs: 40,
          status: 'ok',
        ),
      );
      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(
          rid: 'rid_x',
          name: dispatchRootStageName,
          phase: 'end',
          endMs: 40,
          status: 'ok',
          elapsedMs: 40,
        ),
      );
      await settle();

      expect(c.dispatchProgressSnapshot, isNull, reason: 'root end = 分发结束');
      expect(emitted.last, isNull, reason: '必须显式推 null（消费方据此隐藏）');

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await sub.cancel();
      await c.dispose();
    });

    test('send 返回后同一 rid 的迟到帧不再跟踪', () async {
      // 迟到帧的形态真实存在：分发结束与 HTTP 响应是两个独立通道。
      // 若不在出口撤销，进度条会「自己又活过来」。
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: 'classify.prepare'),
      );
      await settle();
      expect(c.dispatchProgressSnapshot, isNotNull);

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await settle();
      expect(c.dispatchProgressSnapshot, isNull);

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(
          rid: 'rid_x',
          name: 'classify.prepare',
          phase: 'end',
          endMs: 30,
          status: 'ok',
        ),
      );
      await settle();
      expect(c.dispatchProgressSnapshot, isNull, reason: '请求已返回，rid 已不在飞');

      await c.dispose();
    });

    test('群忙 202（deferred）同样收起（服务端没建 turn）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: 'classify.prepare'),
      );
      await settle();
      expect(c.dispatchProgressSnapshot, isNotNull);

      hang.resolve({
        'status': 'deferred',
        'group_id': 'grp_1',
        'inbox_message_id': 'inbox_1',
        'turn_id': '',
      });
      await sending;
      await settle();

      expect(c.dispatchProgressSnapshot, isNull);
      await c.dispose();
    });

    test('切 group 清空（旧对话的分发不该出现在新页面）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: 'classify.llm'),
      );
      await settle();
      expect(c.dispatchProgressSnapshot, isNotNull);

      await c.switchGroup('grp_2');
      expect(c.dispatchProgressSnapshot, isNull);

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await c.dispose();
    });

    test('断线清空（Transient 不回放，留着会停在某一帧上）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: 'classify.llm'),
      );
      await settle();
      expect(c.dispatchProgressSnapshot, isNotNull);

      sse.framesController.addError(Exception('boom'));
      await settle();

      expect(c.dispatchProgressSnapshot, isNull);

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await c.dispose();
    });
  });

  group('不进时间线与游标（Transient + 无 turn）', () {
    test('分发帧不产出对话项、不推进游标', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');
      final sending = c.send(
        input: '你好',
        groupId: 'grp_1',
        // 显式给 rid：分发帧靠它归因，随机 UUID 没法在用例里写死。
        requestId: 'rid_x',
      );
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: 'classify.llm'),
      );
      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(
          rid: 'rid_x',
          name: 'classify.llm',
          phase: 'end',
          endMs: 20,
          status: 'ok',
        ),
      );
      await settle();

      // 只有乐观回显那一条（本次 send 的本地注入），没有分发帧变成的条目。
      expect(c.snapshot, hasLength(1));
      expect(c.snapshot.single, isA<UserMessageItem>());
      // 游标一次都没被推进：推进了会让断线回放以「不存在的 eventId」定位。
      expect(sse.recordedEventIds, isEmpty);

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await c.dispose();
    });
  });

  group('诊断日志（Transient 帧在服务端不可观测，只能靠客户端留痕）', () {
    // `dispatch_stage` 不落库、服务端不打日志（§6.106），所以「进度条没出现」
    // 在服务端查不到任何痕迹。这一格日志是唯一的观测手段，因此它的**级别**
    // 与**去重**也必须钉住：级别低了（debug）在 release 里根本不落 = 等于没有；
    // 不去重则别的设备的分发帧会把日志刷满。

    test('首个可归因帧记一条 info（含 rid / 段名 / 相位）', () async {
      SpbLog.clearRecentLogs();
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      final sub = c.dispatchProgress.listen((_) {});

      await c.start(groupId: 'grp_1');
      final sending = c.send(input: '你好', groupId: 'grp_1', requestId: 'rid_x');
      await hang.waitForRequest();

      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: dispatchRootStageName),
      );
      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_x', name: 'classify.llm', phase: 'end'),
      );
      await settle();

      final logs = SpbLog.recentLogs.where((r) => r.message == '分发进度：收到首个可归因帧');
      expect(logs, hasLength(1), reason: '每 rid 只记一条，否则一次发送要记十几条');
      expect(logs.single.level, LogLevel.info, reason: 'debug 在 release 里不落');
      expect(logs.single.fields['request_id'], 'rid_x');
      expect(logs.single.fields['name'], dispatchRootStageName);
      expect(logs.single.fields['phase'], 'start');

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await sub.cancel();
      await c.dispose();
    });

    test('rid 不属于本端的帧记一次 warn（同 rid 不重复）', () async {
      SpbLog.clearRecentLogs();
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      final sub = c.dispatchProgress.listen((_) {});

      await c.start(groupId: 'grp_1');
      final sending = c.send(input: '你好', groupId: 'grp_1', requestId: 'rid_x');
      await hang.waitForRequest();

      // 别的设备的分发帧：同一条 user 级订阅上**本来就会出现**，UI 必须丢；
      // 但若本端帧也落进这一格（rid 生成时机不一致），这条 warn 就是唯一线索。
      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(rid: 'rid_other_device', name: 'classify.prepare'),
      );
      sse.push(
        EventTypes.dispatchStage,
        dispatchFrame(
          rid: 'rid_other_device',
          name: 'classify.prepare',
          phase: 'end',
        ),
      );
      await settle();

      final warns = SpbLog.recentLogs.where(
        (r) => r.message == 'dispatch 帧的 request_id 不属于本端（已丢弃）',
      );
      expect(warns, hasLength(1), reason: '按 rid 去重，否则每帧一条');
      expect(warns.single.level, LogLevel.warn);
      expect(warns.single.fields['request_id'], 'rid_other_device');
      expect(warns.single.fields['in_flight'], 1);
      expect(c.dispatchProgressSnapshot, isNull, reason: '别的设备的帧不得进 UI');

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await sub.cancel();
      await c.dispose();
    });

    test('缺 request_id 的帧记一条 warn（契约破坏）', () async {
      SpbLog.clearRecentLogs();
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      final sub = c.dispatchProgress.listen((_) {});

      await c.start(groupId: 'grp_1');
      final sending = c.send(input: '你好', groupId: 'grp_1', requestId: 'rid_x');
      await hang.waitForRequest();

      final broken = dispatchFrame(rid: 'rid_x', name: 'classify.llm')
        ..['payload'] = {'phase': 'start', 'name': 'classify.llm'};
      sse.push(EventTypes.dispatchStage, broken);
      await settle();

      final warns = SpbLog.recentLogs.where(
        (r) => r.message == 'dispatch 帧缺少 request_id（已丢弃）',
      );
      expect(warns, hasLength(1));
      expect(warns.single.level, LogLevel.warn);

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await sub.cancel();
      await c.dispose();
    });
  });
}
