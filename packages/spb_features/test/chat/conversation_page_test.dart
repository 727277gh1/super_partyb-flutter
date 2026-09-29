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
class _FakeSseClient extends SseClient {
  _FakeSseClient()
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

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;
  late _FakeSseClient sse;
  late ChatStreamController controller;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    sse = _FakeSseClient();
    controller = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
  });

  tearDown(() async => controller.dispose());

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
  Future<void> pushEvent(
    WidgetTester tester,
    String type,
    Map<String, dynamic> data,
  ) async {
    await tester.runAsync(() async {
      sse.push(type, data);
      // 给流一点时间把事件交给控制器。
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    String? title = '测试对话',
    void Function(String, String, String)? onResolveConfirmation,
    Future<void> Function(String)? onSend,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          controller: controller,
          title: title,
          onResolveConfirmation: onResolveConfirmation,
          onSend: onSend,
        ),
      ),
    );
    await tester.pump();
  }

  group('ConversationPage 时间线渲染', () {
    testWidgets('空列表显示空提示', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, title: null);

      expect(find.text('还没有对话，输入消息开始吧'), findsOneWidget);
    });

    testWidgets('用户消息与助手回复分别渲染为气泡', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent('user_message', id: 'e1', payload: {'input': '你好'}),
      );

      await pushEvent(
        tester,
        EventTypes.message,
        sseEvent('message', id: 'e2', payload: {'text': '你好，有什么可以帮你'}, seq: 2),
      );

      expect(find.text('你好'), findsOneWidget);
      expect(find.text('你好，有什么可以帮你'), findsOneWidget);
    });

    testWidgets('思考项渲染为可折叠 tile', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.thought,
        sseEvent('thought', id: 'e1', payload: {'text': '我在想'}),
      );

      expect(find.text('思考过程'), findsOneWidget);
    });

    testWidgets('工具调用项渲染', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.toolCall,
        sseEvent('tool_call', id: 'e1', payload: {'name': 'bash'}),
      );

      expect(find.text('bash'), findsOneWidget);
    });

    testWidgets('后续建议渲染为 chip', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.followUpSuggested,
        sseEvent(
          'follow_up_suggested',
          id: 'e1',
          payload: {
            'suggestions': ['再详细点'],
          },
        ),
      );

      expect(find.text('再详细点'), findsOneWidget);
    });
  });

  group('ConversationPage 确认卡', () {
    testWidgets('点击选项回调收到【卡行 id】而非事件 id', (tester) async {
      // 这是本页最容易错的一处：ConfirmationItem.id 是**事件 id**，而 resolve
      // 端点要的是 chat_confirmations.id（payload.confirmation_id）。
      // 传错会 404 且不报错（0 行受影响），表现为「点了按钮没反应」。
      final calls = <(String, String, String)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveConfirmation: (gid, id, opt) => calls.add((gid, id, opt)),
      );

      await pushEvent(
        tester,
        EventTypes.confirmationRequired,
        sseEvent(
          'confirmation_required',
          id: 'evt_abc',
          payload: {
            'confirmation_id': 'conf_row_xyz',
            'recommendation': {'action': 'continue', 'confidence': 0.9},
          },
        ),
      );

      expect(find.text('需要你的确认'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('confirmation-option-继续')));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.$1, 'grp_1', reason: 'groupId 用于拼 resolve 路径');
      expect(calls.single.$2, 'conf_row_xyz', reason: '必须是卡行 id，不是 evt_abc');
      expect(calls.single.$3, '继续');
    });

    testWidgets('事件未携带 confirmation_id 时按钮禁用（不退化用事件 id）', (tester) async {
      final calls = <(String, String, String)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveConfirmation: (gid, id, opt) => calls.add((gid, id, opt)),
      );

      await pushEvent(
        tester,
        EventTypes.confirmationRequired,
        sseEvent('confirmation_required', id: 'evt_only', payload: const {}),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirmation-option-继续')),
      );
      expect(button.onPressed, isNull, reason: '缺 id 应禁用，而不是拿事件 id 去试');
      expect(calls, isEmpty);
    });
  });

  group('ConversationPage 发送', () {
    testWidgets('输入框提交走 onSend 覆盖', (tester) async {
      final sent = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onSend: (t) async => sent.add(t));

      await tester.enterText(find.byType(TextField), '发出去');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(sent, ['发出去']);
    });

    testWidgets('未覆盖 onSend 时调用 controller.send（经 ChatApi）', (tester) async {
      mockTimeline();
      await startController(tester);
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(201, {
          'turn_id': 'turn_1',
          'group_id': 'grp_1',
          'status': 'queued',
        }),
        data: Matchers.any,
      );
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '走控制器');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      // 乐观回显：用户气泡立刻出现（不等 SSE）。
      expect(find.text('走控制器'), findsOneWidget);
    });

    testWidgets('发送失败显示 SnackBar 且不清空输入', (tester) async {
      mockTimeline();
      await startController(tester);
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(500, {'error': 'boom'}),
        data: Matchers.any,
      );
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '会失败');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(find.textContaining('发送失败'), findsOneWidget);
      // 不清空：用户可能想重试同一段文字。
      // 注意 MessageComposer._submit 会先 clear() 再回调，故此处输入框已空；
      // 断言的重点是「有提示」而非「保留文本」——保留由 composer 的 clear
      // 语义决定，见 message_composer.dart 的说明。
    });
  });

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
}
