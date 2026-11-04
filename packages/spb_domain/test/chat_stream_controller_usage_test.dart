import 'dart:async';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// group 级 token 消耗（`usage-summary` 基线 + `token_usage` 增量）。
///
/// 真源：Go `server/chat_usage.go`（聚合端点）与 `chatexec/usage.go`
/// （事件 payload）。webapp 的对应实现在
/// `use-workbench-state.ts` 的 `applyUsageIncrement`。
///
/// ## 为什么要「基线 + 增量」两条路径
///
/// 总量必须来自服务端：`token_usage` 是落库事件，但客户端缓冲有上限
/// （2000 条、按整轮裁剪），从缓冲求和会**越用越少**。故 REST 给基线，
/// SSE 只把**实时**到达的账加上去。
void main() {
  setUpHarness();

  /// 转几个事件循环轮次（dio 的请求要跨多跳微任务）。
  Future<void> settle([int hops = 8]) async {
    for (var i = 0; i < hops; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 挂 `usage-summary` 的 mock（全 snake_case，与 Go DTO 一致）。
  void mockUsage(
    String groupId, {
    int calls = 3,
    int input = 100,
    int output = 50,
    int cached = 20,
    String firstAt = '2026-11-01T02:03:04Z',
    String lastAt = '2026-11-02T02:03:04Z',
    bool withAgents = false,
  }) {
    adapter.onGet(
      '/chat/groups/$groupId/usage-summary',
      (server) => server.reply(200, {
        'totals': {
          'input_tokens': input,
          'output_tokens': output,
          'cached_tokens': cached,
          'reasoning_tokens': 0,
          'total_tokens': input + output,
          'calls': calls,
          'first_at': firstAt,
          'last_at': lastAt,
        },
        'by_agent': withAgents
            ? [
                {
                  'agent_id': 'agt_1',
                  'agent_name': '小明',
                  'input_tokens': input,
                  'output_tokens': output,
                  'cached_tokens': cached,
                  'calls': calls,
                },
              ]
            : <Object?>[],
      }),
    );
  }

  group('用量基线（REST）', () {
    test('start 拉取 usage-summary，缓存与流都拿到基线', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      final seen = <GroupUsageSummary?>[];
      final sub = c.usageSummary.listen(seen.add);
      mockTimeline();
      mockUsage('grp_1');

      await c.start(groupId: 'grp_1');
      await settle();

      expect(c.usageSummarySnapshot?.totals.calls, 3);
      expect(c.usageSummarySnapshot?.totals.inputTokens, 100);
      // 首帧（重置时推的 null）之后必须有一个非空基线。
      expect(seen.whereType<GroupUsageSummary>(), isNotEmpty);

      await sub.cancel();
      await c.dispose();
    });

    test('端点失败 → 静默不显示（不抛、不推错误、快照为 null）', () async {
      // 用量是一块只读读数：拉取失败应降级成「不显示」，
      // 而不是给用户一个错误提示（同 webapp 的 `catch {}`）。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      final seen = <GroupUsageSummary?>[];
      final sub = c.usageSummary.listen(seen.add);
      final errors = <SpbError>[];
      final errSub = c.errors.listen(errors.add);
      mockTimeline();
      // 刻意不注册 usage-summary：dio 会抛（真实是 404/网络错误）。

      await c.start(groupId: 'grp_1');
      await settle();

      expect(c.usageSummarySnapshot, isNull);
      expect(seen.whereType<GroupUsageSummary>(), isEmpty);
      expect(errors, isEmpty, reason: '读数失败不得污染错误流（那会弹给用户）');

      await sub.cancel();
      await errSub.cancel();
      await c.dispose();
    });

    test('重连（SseState.connected）后向服务端对一次账', () async {
      // 断线期间错过的 token_usage 若不在回放窗口内，本地增量会偏小且再也补不
      // 回来；重连是一个零成本的「该重拉了」信号。
      final probe = _UsageProbe()..calls = 3;
      final localDio = createDio(baseUrl: 'https://api.test/pba')
        ..interceptors.add(probe);
      final c = ChatStreamController(
        sse: sse,
        api: ChatApi(localDio),
        userId: 'usr_1',
      );

      await c.start(groupId: 'grp_1');
      await settle();
      expect(probe.usageRequests, 1);
      expect(c.usageSummarySnapshot?.totals.calls, 3);

      probe.calls = 8; // 服务端在此期间又记了几轮账
      sse.statesController.add(SseState.connected);
      await settle();

      expect(probe.usageRequests, 2, reason: '重连必须重新拉基线（本地增量只覆盖实时到达的那一段）');
      expect(c.usageSummarySnapshot?.totals.calls, 8);

      await c.dispose();
    });

    test('全局模式（列表页建的连接）重连不拉用量', () async {
      // 没打开任何对话时 `groupId == null`——为一个不存在的账单发请求属纯噪声。
      final probe = _UsageProbe();
      final localDio = createDio(baseUrl: 'https://api.test/pba')
        ..interceptors.add(probe);
      final c = ChatStreamController(
        sse: sse,
        api: ChatApi(localDio),
        userId: 'usr_1',
      );

      await c.ensureConnected();
      sse.statesController.add(SseState.connected);
      await settle();

      expect(probe.usageRequests, 0);

      await c.dispose();
    });

    test('refreshUsageSummary 可重拉（无聚焦 group 时是空操作）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');

      // 尚未 start：无 groupId，空操作且不抛。
      await c.refreshUsageSummary();

      mockTimeline();
      mockUsage('grp_1', calls: 3);
      await c.start(groupId: 'grp_1');
      await settle();
      expect(c.usageSummarySnapshot?.totals.calls, 3);

      // 重新挂一个更大的基线（adapter 的同一 path 注册后到者生效）。
      mockUsage('grp_1', calls: 11);
      await c.refreshUsageSummary();
      expect(c.usageSummarySnapshot?.totals.calls, 11);

      await c.dispose();
    });

    test('切 group：先清基线，再换成新 group 的基线', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      final seen = <GroupUsageSummary?>[];
      final sub = c.usageSummary.listen(seen.add);
      mockTimeline();
      mockUsage('grp_1', calls: 3);
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Object?>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );
      mockUsage('grp_2', calls: 7, input: 900, output: 100);

      await c.start(groupId: 'grp_1');
      await settle();
      expect(c.usageSummarySnapshot?.totals.calls, 3);

      seen.clear();
      await c.switchGroup('grp_2');
      await settle();

      expect(c.usageSummarySnapshot?.totals.calls, 7);
      expect(c.usageSummarySnapshot?.totals.burnedTokens, 1000);
      // 切过去的第一帧必须是 null（否则旧对话的账单会在新对话首帧继续显示）。
      expect(seen.first, isNull, reason: '切 group 先清基线，再等新基线落地');

      await sub.cancel();
      await c.dispose();
    });

    test('旧 group 的迟到响应不得覆盖当前 group 的基线', () async {
      // 请求在飞期间用户切了对话：晚到的响应会把 A 的账单挂到 B 上
      // （跨对话串数据，比不显示更糟）。
      final gate = _UsageGate();
      final localDio = createDio(baseUrl: 'https://api.test/pba');
      localDio.interceptors.add(gate);
      final c = ChatStreamController(
        sse: sse,
        api: ChatApi(localDio),
        userId: 'usr_1',
      );

      // start 内部不 await 基线请求 → 返回时 grp_1 的请求仍挂在闸门上。
      await c.start(groupId: 'grp_1');
      await settle();
      expect(gate.pending, contains('grp_1'));

      await c.switchGroup('grp_2');
      await settle();
      expect(gate.pending, contains('grp_2'));

      // 后发先至：grp_2 先回，grp_1 迟到。
      gate.release('grp_2', calls: 9);
      await settle();
      expect(c.usageSummarySnapshot?.totals.calls, 9);

      gate.release('grp_1', calls: 99);
      await settle();
      expect(
        c.usageSummarySnapshot?.totals.calls,
        9,
        reason: 'grp_1 的迟到响应必须被 _groupId 归属校验丢弃',
      );

      await c.dispose();
    });
  });

  group('token_usage 本地增量（SSE）', () {
    test('基线就绪后事件累加 totals，calls 恒 +1', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      mockUsage('grp_1', calls: 3, input: 100, output: 50, cached: 20);
      await c.start(groupId: 'grp_1');
      await settle();
      expect(c.usageSummarySnapshot?.totals.calls, 3);

      sse.push(
        EventTypes.tokenUsage,
        sseEvent(
          EventTypes.tokenUsage,
          id: 'usage_1',
          payload: {
            'input_tokens': 1000,
            'output_tokens': 200,
            'cached_tokens': 300,
            'calls': 7, // ← 本轮内的 LLM 请求帧数，**不**用于合计
          },
        ),
      );
      await settle();

      final t = c.usageSummarySnapshot!.totals;
      expect(t.calls, 4, reason: 'calls 是事件条数（服务端 COUNT(*)），不是 payload.calls');
      expect(t.inputTokens, 1100);
      expect(t.outputTokens, 250);
      expect(t.cachedTokens, 320);
      // cached 是 input 的子集，不参与加总。
      expect(t.burnedTokens, 1350);

      await c.dispose();
    });

    test('流会推出增量后的快照（页面直接刷新读数）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      mockUsage('grp_1', calls: 1, input: 10, output: 5);
      await c.start(groupId: 'grp_1');
      await settle();

      final seen = <GroupUsageSummary?>[];
      final sub = c.usageSummary.listen(seen.add);

      sse.push(
        EventTypes.tokenUsage,
        sseEvent(
          EventTypes.tokenUsage,
          id: 'usage_1',
          payload: {'input_tokens': 10, 'output_tokens': 5},
        ),
      );
      await settle();

      expect(seen.whereType<GroupUsageSummary>(), isNotEmpty);
      expect(seen.whereType<GroupUsageSummary>().last.totals.calls, 2);

      await sub.cancel();
      await c.dispose();
    });

    test('基线未就绪时跳过增量（避免与随后落地的基线双重计数）', () async {
      // 基线请求在飞 / 刚切 group 时快照为 null。此时若先累加再叠加晚到的基线，
      // 会算两遍。跳过 → 基线自会包含它；偏好「少算」而非「多算」。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      // 不注册 usage-summary ⇒ 基线永远拉不到。
      await c.start(groupId: 'grp_1');
      await settle();
      expect(c.usageSummarySnapshot, isNull);

      final seen = <GroupUsageSummary?>[];
      final sub = c.usageSummary.listen(seen.add);
      sse.push(
        EventTypes.tokenUsage,
        sseEvent(
          EventTypes.tokenUsage,
          id: 'usage_early',
          payload: {'input_tokens': 500, 'output_tokens': 100},
        ),
      );
      await settle();

      expect(c.usageSummarySnapshot, isNull, reason: '不得凭空造出一个只有增量的账单');
      expect(seen.whereType<GroupUsageSummary>(), isEmpty);

      await sub.cancel();
      await c.dispose();
    });

    test('其他 group 的事件不累加（SSE 是 user 级订阅）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      mockUsage('grp_1', calls: 3, input: 100, output: 50);
      await c.start(groupId: 'grp_1');
      await settle();

      sse.push(
        EventTypes.tokenUsage,
        sseEvent(
          EventTypes.tokenUsage,
          id: 'usage_other',
          groupId: 'grp_other',
          payload: {'input_tokens': 9999, 'output_tokens': 9999},
        ),
      );
      await settle();

      expect(c.usageSummarySnapshot?.totals.calls, 3);
      expect(c.usageSummarySnapshot?.totals.inputTokens, 100);

      await c.dispose();
    });

    test('事件照常推进游标，但不进时间线（观测数据不挤占对话事件）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      mockUsage('grp_1', calls: 1, input: 10, output: 5);
      await c.start(groupId: 'grp_1');
      await settle();

      sse.push(
        EventTypes.tokenUsage,
        sseEvent(
          EventTypes.tokenUsage,
          id: 'usage_cursor',
          payload: {'input_tokens': 10, 'output_tokens': 5},
        ),
      );
      await settle();

      // 它是落库事件（有有效 eventId）⇒ 断线回放要覆盖它。
      expect(sse.recordedEventIds, contains('usage_cursor'));
      // 归约器无 case ⇒ 不产生任何时间线条目。
      expect(c.snapshot, isEmpty);

      await c.dispose();
    });

    test('transient 的 token_usage 不推游标（防御：服务端将来改成增量帧）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      mockUsage('grp_1', calls: 1, input: 10, output: 5);
      await c.start(groupId: 'grp_1');
      await settle();

      sse.push(
        EventTypes.tokenUsage,
        sseEvent(
          EventTypes.tokenUsage,
          id: 'usage_tx',
          transient: true,
          payload: {'input_tokens': 10, 'output_tokens': 5},
        ),
      );
      await settle();

      expect(sse.recordedEventIds, isNot(contains('usage_tx')));

      await c.dispose();
    });
  });
}

/// 把 `usage-summary` 请求挂在闸门上的拦截器（测「迟到响应不得覆盖」）。
///
/// ## 为什么不用 `DioAdapter`
///
/// 它没有延迟能力：注册即返回，于是「响应在切 group 之后才到」这个时序
/// 根本构造不出来（用例会在缺陷代码上变绿）。这里用 `chat` 之外的独立 dio
/// + 一个可手动放行的拦截器，时序完全由测试控制。
/// 统计 `usage-summary` 请求次数并即时应答的拦截器。
///
/// ## 为什么不用 `DioAdapter` 计数
///
/// `http_mock_adapter` 的 handler 会在**注册时**就被调用一次（用于构造响应），
/// 于是「handler 里的自增计数」测的是注册次数而不是请求次数——用例会在
/// 「一次都不发请求」的错误实现上变红、在「每次都发」的实现上也红，完全失去
/// 判别力（实测踩过）。故计数必须放在**请求路径**上。
class _UsageProbe extends Interceptor {
  /// 已发出的 `usage-summary` 请求数。
  int usageRequests = 0;

  /// 下一次应答里的 `calls`（测试可在两阶段之间改它，借此断言快照被刷新）。
  int calls = 3;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;
    if (path.endsWith('/timeline')) {
      handler.resolve(
        Response<Map<String, dynamic>>(
          requestOptions: options,
          statusCode: 200,
          data: {'items': <Object?>[], 'next_before_global_seq': ''},
        ),
      );
      return;
    }
    if (path.contains('/usage-summary')) {
      usageRequests++;
      handler.resolve(
        Response<Map<String, dynamic>>(
          requestOptions: options,
          statusCode: 200,
          data: {
            'totals': {
              'input_tokens': calls,
              'output_tokens': 0,
              'calls': calls,
            },
            'by_agent': <Object?>[],
          },
        ),
      );
      return;
    }
    // 其余路径（turn-runtime 等）交给 dio：真实网络失败，由生产代码的 catch 兜住。
    handler.next(options);
  }
}

class _UsageGate extends Interceptor {
  /// groupId → 放行时用的 calls 值。
  final _waiters = <String, Completer<int>>{};

  /// 当前还被扣着的 groupId。
  final pending = <String>{};

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;
    if (path.endsWith('/timeline')) {
      handler.resolve(
        Response<Map<String, dynamic>>(
          requestOptions: options,
          statusCode: 200,
          data: {'items': <Object?>[], 'next_before_global_seq': ''},
        ),
      );
      return;
    }
    if (path.contains('/usage-summary')) {
      // `/chat/groups/<gid>/usage-summary`
      final segments = path.split('/');
      final gid = segments.length > 3 ? segments[3] : '';
      final completer = Completer<int>();
      _waiters[gid] = completer;
      pending.add(gid);
      unawaited(
        completer.future.then((calls) {
          pending.remove(gid);
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'totals': {
                  'input_tokens': 1,
                  'output_tokens': 1,
                  'calls': calls,
                },
                'by_agent': <Object?>[],
              },
            ),
          );
        }),
      );
      return;
    }
    handler.next(options);
  }

  /// 放行某个 group 的基线请求。
  void release(String gid, {required int calls}) {
    final completer = _waiters.remove(gid);
    if (completer == null) {
      fail('没有待放行的 usage-summary 请求：$gid');
    }
    completer.complete(calls);
  }
}
