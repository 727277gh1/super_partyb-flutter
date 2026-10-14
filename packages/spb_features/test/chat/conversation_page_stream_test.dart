import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// ConversationPage 连接状态 / 自动滚动 / 加载更早历史 / 重连 / 语音播报
///
/// ⚠️ 本文件由 `conversation_page_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `test/support/conversation_page_harness.dart`。
void main() {
  setUpHarness();
  tearDownHarness();

  group('ConversationPage 连接状态', () {
    testWidgets('title 为 null 时不渲染 AppBar', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, title: null);

      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('title 非 null 时渲染 AppBar 与连接指示', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    });
  });

  group('ConversationPage 自动滚到底', () {
    testWidgets('内容溢出时新项到达会自动滚到底', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      // 塞足够多内容让列表溢出。
      //
      // ⚠️ 每个 turn 必须先推 `start`：它是**段落边界**（reducer 在此重置
      // `currentAssistantIdx`）。服务端确实会落库并回放 start 事件
      // （`turn_worker.go:656`，timeline 不过滤事件类型），故真实场景不缺它。
      // 少了 start，不同 turn 的权威帧会被当成同一段落的替换而塌缩成一项。
      for (var i = 0; i < 30; i++) {
        await pushEvent(
          tester,
          EventTypes.start,
          sseEvent('start', id: 's$i', turnId: 'turn_$i', seq: 1),
        );
        await pushEvent(
          tester,
          EventTypes.message,
          sseEvent(
            'message',
            id: 'e$i',
            turnId: 'turn_$i',
            payload: {'text': '第 $i 条消息内容'},
            seq: 2,
          ),
        );
      }
      await tester.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason: '内容应已溢出，否则本用例无意义',
      );
      expect(
        position.pixels,
        closeTo(position.maxScrollExtent, 1),
        reason: '在底部时新项应自动跟随',
      );
    });
  });

  group('ConversationPage 加载更早历史', () {
    /// 塞入 [count] 条独立消息，让列表溢出以便产生滚动。
    ///
    /// 用 `user_message`（每条 turnId 不同 → 独立成项）：非 transient 的
    /// `message` 是权威帧，会被 reducer 当成同段落的替换而塌缩成一项。
    Future<void> seedMessages(WidgetTester tester, int count) async {
      for (var i = 0; i < count; i++) {
        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            'user_message',
            id: 'u$i',
            turnId: 'turn_$i',
            payload: {'input': '第 $i 条'},
            seq: i + 1,
          ),
        );
      }
      await tester.pump();
    }

    testWidgets('滚动到顶部时触发 onLoadOlder', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        onLoadOlder: () async {
          calls++;
          return true; // 还有更多
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      expect(calls, 0, reason: '初始在底部，不应触发翻页');

      // 向上拖到底（内容溢出，可滚）。
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      expect(calls, greaterThan(0), reason: '滚到顶部附近必须触发翻页');
    });

    testWidgets('滚动过程中并发触发时只调一次 handler', (tester) async {
      // 一次拖拽会产生**很多**次滚动通知，而 handler 内部是异步请求。
      // 没有护栏就会并发发出多个翻页请求（都带同一游标 → 拉到同一页）。
      //
      // 这里必须让 handler **挂起**（不立即完成）：否则第一次调用就 resolve 了，
      // 后续通知看到的是「未在加载」，护栏根本不会被触发到——那正是这条用例
      // 存在的意义（域层的护栏会掩盖掉页面的护栏）。
      mockTimeline();
      await startController(tester);
      var calls = 0;
      final gate = Completer<bool>();
      await pumpPage(
        tester,
        onLoadOlder: () {
          calls++;
          return gate.future;
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      // ⚠️ 这里的手势形状是**被实测逼出来的**，不能改成 `tester.drag`：
      //
      // 1. `tester.drag` 只产生一次滚动通知 → 护栏无从体现；
      // 2. 光用「连续 moveBy 拖到顶」也不行——到达 `pixels == 0` 后再拖不会
      //    产生新的滚动通知，而恰好只有最后一次通知落在阈值内，护栏同样不被
      //    触发（实测：去掉护栏后用例仍然全绿）。
      //
      // 故：先拖到顶，再在阈值区间内**来回抖动**，制造多次「位置已变」信号。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
      );
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(0, 400));
        await tester.pump();
      }
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();

      expect(calls, 1, reason: '挂起期间不得重复调用 handler');
      expect(gate.isCompleted, isFalse);

      gate.complete(true);
      await tester.pumpAndSettle();
    });

    testWidgets('换 group（historyKey 变化）后重置「已到最早」标记', (tester) async {
      // 回归防线：切 group 时控制器实例不变、State 被复用，若不按 historyKey
      // 重置，在 A 对话翻到头后切到 B 会永远翻不出历史（且毫无报错）。
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        historyKey: 'grp_A',
        onLoadOlder: () async {
          calls++;
          return false; // 已到最早
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      final inA = calls;
      expect(inA, greaterThan(0));

      // 切到另一个对话：historyKey 变，标记必须重置。
      await rebuildPage(
        tester,
        historyKey: 'grp_B',
        onLoadOlder: () async {
          calls++;
          return true;
        },
      );
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      expect(calls, greaterThan(inA), reason: '换了对话后必须重新允许翻页（否则新对话永远翻不出历史）');
    });

    testWidgets('返回 false 后不再触发（已到最早）', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        onLoadOlder: () async {
          calls++;
          return false; // 已到最早
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      final afterFirst = calls;
      expect(afterFirst, greaterThan(0));

      // 再滚一次（回到顶部附近会再次触发滚动通知）。
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      expect(calls, afterFirst, reason: '返回 false 之后不得再发请求（否则每次到顶都白拉一次）');
    });

    testWidgets('未注入 onLoadOlder 时不触发（只读时间线用法）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      // 没有回调可注入，滚到顶也不应抛异常。
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('失败时提示，且仍可再次触发（不标记为已到最早）', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        onLoadOlder: () async {
          calls++;
          throw const NetworkError('断网了');
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(calls, greaterThan(0));
      expect(find.textContaining('加载更早历史失败'), findsOneWidget);

      final afterFirst = calls;
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      expect(
        calls,
        greaterThan(afterFirst),
        reason: '失败后必须允许重试，否则一次网络抖动就永久失去历史',
      );
    });

    testWidgets('空列表时不触发翻页（无锚点）', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        onLoadOlder: () async {
          calls++;
          return true;
        },
      );
      await tester.pumpAndSettle();

      // 空态渲染的是 _EmptyHint，没有 ListView 可滚。
      expect(find.byType(ListView), findsNothing);
      expect(calls, 0);
    });
  });

  group('ConversationPage 重连', () {
    final indicator = find.byKey(
      const ValueKey('conversation-connection-indicator'),
    );

    testWidgets('断线态点击指示器触发一次 onReconnect', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(tester, onReconnect: () => calls++);

      await pushConnectionState(tester, SseState.failed);
      expect(indicator, findsOneWidget);

      await tester.tap(indicator);
      await tester.pump();

      expect(calls, 1, reason: '点击一次必须只回调一次');
    });

    testWidgets('重连中（reconnecting）也可点', (tester) async {
      // 退避最长可到 maxBackoff，用户不该被迫干等计时器。
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(tester, onReconnect: () => calls++);

      await pushConnectionState(tester, SseState.reconnecting);
      await tester.tap(indicator);
      await tester.pump();

      expect(calls, 1);
    });

    testWidgets('已连接态点击不触发（不渲染手势）', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(tester, onReconnect: () => calls++);

      await pushConnectionState(tester, SseState.connected);
      // 已连接态下指示器是纯展示：不存在可点的 InkWell。
      expect(
        find.descendant(of: indicator, matching: find.byType(InkWell)),
        findsNothing,
      );

      await tester.tap(indicator, warnIfMissed: false);
      await tester.pump();

      expect(calls, 0, reason: '已连接时误触不得触发重连（会丢弃正在传输的帧）');
    });

    testWidgets('未注入 onReconnect 时纯展示（任何状态都不可点）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushConnectionState(tester, SseState.failed);
      expect(indicator, findsOneWidget);
      expect(
        find.descendant(of: indicator, matching: find.byType(InkWell)),
        findsNothing,
      );

      // 没有回调，点了也不应抛异常。
      await tester.tap(indicator, warnIfMissed: false);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('图标内边距在可点/不可点之间保持一致（AppBar 不抖动）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onReconnect: () {});

      await pushConnectionState(tester, SseState.connected);
      final connectedSize = tester.getSize(indicator);

      await pushConnectionState(tester, SseState.failed);
      final failedSize = tester.getSize(indicator);

      expect(
        failedSize,
        connectedSize,
        reason: '状态切换不得改变指示器尺寸，否则 AppBar 内容会左右跳动',
      );
    });
  });

  group(
    'ConversationPage 语音播报状态（tts_started / tts_completed / tts_failed）',
    () {
      /// 推一个 TTS 生命周期事件。
      ///
      /// `tts_started` 是 Transient（Go `main.go:715` 只对它设 Transient），
      /// 两个终态事件是**落库**的。
      Future<void> pushTts(
        WidgetTester tester,
        String type,
        Map<String, dynamic> payload, {
        required String id,
        required int seq,
      }) => pushEvent(
        tester,
        type,
        sseEvent(
          type,
          id: id,
          seq: seq,
          transient: type == EventTypes.ttsStarted,
          payload: payload,
        ),
      );

      testWidgets('tts_started 展示「正在生成语音…」', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsStarted,
          {'mode': 'message', 'seq': 1},
          id: 'e_tts_1',
          seq: 10,
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
          reason: '没有它，用户不知道语音在合成还是没开语音',
        );
        expect(find.textContaining('正在生成语音'), findsOneWidget);
      });

      testWidgets('tts_completed 展示「语音已生成」并带段数', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsStarted,
          {'mode': 'stream'},
          id: 'e_tts_2',
          seq: 10,
        );
        await pushTts(
          tester,
          EventTypes.ttsCompleted,
          {'parts': 3, 'bytes': 1024},
          id: 'e_tts_3',
          seq: 11,
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
        );
        expect(find.textContaining('语音已生成'), findsOneWidget);
        expect(find.textContaining('3 段'), findsOneWidget);
      });

      testWidgets('tts_failed 展示服务端文案，不暴露内部 reason', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsFailed,
          {'reason': 'synthesize_failed', 'message': '语音生成失败，本次文本回复不受影响。'},
          id: 'e_tts_4',
          seq: 10,
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
        );
        expect(find.textContaining('语音生成失败，本次文本回复不受影响。'), findsOneWidget);
        expect(
          find.textContaining('synthesize_failed'),
          findsNothing,
          reason: 'reason 是诊断值，不是给用户看的文案',
        );
      });

      testWidgets('tts_failed 缺 message 时兜底「语音生成失败。」', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsFailed,
          {'reason': 'boom'},
          id: 'e_tts_5',
          seq: 10,
        );

        expect(find.textContaining('语音生成失败。'), findsOneWidget);
      });

      testWidgets('部分成功与全失败文案不同（由服务端区分）', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsFailed,
          {
            'parts': 5,
            'failed_part': 3,
            'completed_parts': 2,
            'lost_chars': 42,
            'message': '语音生成未完全成功，已生成的部分仍可播放。',
          },
          id: 'e_tts_6',
          seq: 10,
        );

        expect(find.textContaining('已生成的部分仍可播放'), findsOneWidget);
      });

      testWidgets('started → completed 覆盖，不留两个指示条', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsStarted,
          {'mode': 'stream'},
          id: 'e_tts_7',
          seq: 10,
        );
        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
        );

        await pushTts(
          tester,
          EventTypes.ttsCompleted,
          {'parts': 1},
          id: 'e_tts_8',
          seq: 11,
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
          reason: '状态条是单值指示，不得叠加',
        );
        expect(find.textContaining('正在生成语音'), findsNothing);
      });

      testWidgets('无播报事件时（idle）不占一行', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsNothing,
          reason: 'idle 是默认态，不得为它占一行空白（否则每个对话都多一条）',
        );
      });

      testWidgets('新 turn 的 user_message 后旧播报状态不再展示', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsCompleted,
          {'parts': 1},
          id: 'e_tts_a',
          seq: 10,
        );
        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
        );

        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'e_um_2',
            turnId: 'turn_2',
            seq: 20,
            payload: {'input': '下一个问题'},
          ),
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsNothing,
          reason: '上一轮的「语音已生成」不该粘在新一轮上',
        );
      });

      testWidgets('未接线 ttsStatus 时不展示状态条', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester, wireTtsStatus: false);

        sse.push(
          EventTypes.ttsCompleted,
          sseEvent(
            EventTypes.ttsCompleted,
            id: 'e_tts_9',
            seq: 10,
            payload: {'parts': 1},
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsNothing,
          reason: '未注入时本页不应展示播报状态',
        );
      });
    },
  );

  /// 「立即发送」的透传：本页只是把注入的回调交给两个子组件。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 本页有**两个**入口会触发 flush（输入框的闪电按钮、待处理栏的发送按钮），
  /// 而它们各自的回调是分开的两个构造参数。漏透传任何一个都会造成「一端能选
  /// 策略、另一端死锁」——且两者都能编译通过，只有真实点击才会暴露。
  group('ConversationPage 立即发送透传', () {
    testWidgets('输入框的「立即发送」走注入的 onFlush', (tester) async {
      mockTimeline();
      await startController(tester);
      var flushes = 0;
      await pumpPage(
        tester,
        onFlush: () async {
          flushes++;
          return FlushResult.fromJson({'turn_id': 'turn_1'});
        },
      );

      await tester.tap(find.byKey(const ValueKey('composer-flush')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(flushes, 1);
    });

    testWidgets('待处理栏的「立即发送」也走同一个 onFlush（并透传选策略回调）', (tester) async {
      mockTimeline();
      await startController(tester);
      final strategies = <String>[];
      await pumpPage(
        tester,
        onFlush: () async => FlushResult.fromJson({
          'status': 'confirmation_required',
          'options': ['latest_only', 'merge_all'],
        }),
        onFlushWithStrategy: (strategy) async {
          strategies.add(strategy);
          return FlushResult.fromJson({'turn_id': 'turn_1'});
        },
        loadPending: () async => [
          ChatInboxMessage.fromJson({
            'id': 'inbox_1',
            'user_id': 'usr_1',
            'group_id': 'grp_1',
            'input': '第一条',
            'status': 'pending',
            'created_at': '2024-03-05T08:09:10Z',
            'updated_at': '2024-03-05T08:09:10Z',
          }),
          ChatInboxMessage.fromJson({
            'id': 'inbox_2',
            'user_id': 'usr_1',
            'group_id': 'grp_1',
            'input': '第二条',
            'status': 'pending',
            'created_at': '2024-03-05T08:09:11Z',
            'updated_at': '2024-03-05T08:09:11Z',
          }),
        ],
        undoPending: (_) async {},
        historyKey: 'grp_1',
      );

      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('有多条待处理消息'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('flush-strategy-merge_all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(strategies, ['merge_all'], reason: '待处理栏的入口也必须能选策略，否则它仍是死锁');
    });
  });
}
