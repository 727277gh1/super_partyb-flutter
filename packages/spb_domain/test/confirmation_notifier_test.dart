import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 记录发出的通知（并模拟权限结果）。
class _RecordingSink implements NotificationSink {
  _RecordingSink({this.granted = true});

  bool granted;
  int permissionCalls = 0;
  final sent = <LocalNotification>[];
  void Function(String? payload)? onSelect;

  @override
  Future<bool> requestPermission() async {
    permissionCalls++;
    return granted;
  }

  @override
  Future<void> show(LocalNotification notification) async {
    sent.add(notification);
  }
}

ConfirmationItem _card({
  String id = 'conf_1',
  String question = '要删除这个文件吗？',
  bool resolved = false,
  String groupId = 'grp_1',
}) => ConfirmationItem(
  id: 'ev_$id',
  createdAt: DateTime(2024, 3, 5, 12),
  question: question,
  resolved: resolved,
  confirmationId: id,
  groupId: groupId,
);

/// [ConfirmationNotifier] 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 通知做错的代价不是「功能不可用」而是**骚扰用户**——而骚扰的三种典型来源
/// 恰好都是不会报错的逻辑漏洞：
///
/// 1. **SSE 重连回放**导致同一张卡弹几十次（漏判重）；
/// 2. 用户**正看着对话**时弹窗（漏前台判定）；
/// 3. Android 上**反复弹权限框**（漏权限幂等）。
///
/// 三者都必须有专门用例。
void main() {
  group('只对新确认卡发通知', () {
    test('新的未解决确认卡 → 发一条', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      final sent = await notifier.handleItems([_card()]);

      expect(sent, hasLength(1));
      expect(sink.sent, hasLength(1));
      expect(sink.sent.single.id, 'conf_1');
      expect(sink.sent.single.body, '要删除这个文件吗？');
    });

    test('同 id 重复出现（SSE 重连回放）→ 只发一次', () async {
      // 这是通知功能最容易做错的地方：SSE 的 cursor 回放会把同一张卡再推一次。
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card()]);
      await notifier.handleItems([_card()]);
      await notifier.handleItems([_card()]);
      // 一次推一批（回放可能一次给多条）。
      await notifier.handleItems([_card(), _card()]);

      expect(sink.sent, hasLength(1), reason: '同一张卡重复推送不得重复弹');
    });

    test('同一次 handleItems 里同 id 出现两次 → 只发一次', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(), _card()]);

      expect(sink.sent, hasLength(1));
    });

    test('两个不同的新卡 → 各发一条', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([
        _card(id: 'conf_a', question: 'A'),
        _card(id: 'conf_b', question: 'B'),
      ]);

      expect(sink.sent.map((n) => n.id), ['conf_a', 'conf_b']);
    });

    test('没有确认卡时不发（普通消息不该触发通知）', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      final sent = await notifier.handleItems([
        AssistantMessageItem(
          id: 'ev_1',
          createdAt: DateTime(2024),
          text: '普通回复',
        ),
      ]);

      expect(sent, isEmpty);
      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 0, reason: '无事可发时不该请求权限');
    });

    test('已解决的卡不发（历史回填会推旧卡）', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(resolved: true)]);

      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 0);
    });

    test('已解决后又被推来（状态回退）也不发', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(resolved: true)]);
      await notifier.handleItems([_card(resolved: false)]);

      expect(sink.sent, isEmpty);
    });

    test('confirmationId 为空的异常载荷不发（无法判重也不可 resolve）', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(id: '')]);

      expect(sink.sent, isEmpty);
      expect(notifier.notifiedCount, 0);
    });
  });

  group('窗口聚焦时不打扰', () {
    test('聚焦中 → 不发通知', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => true,
      );

      await notifier.handleItems([_card()]);

      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 0, reason: '不发就不该请求权限');
    });

    test('聚焦时看到的卡在之后切到后台也不补弹', () async {
      // ## 这个测试防的是什么
      //
      // 若前台时不记入判重集合，用户「看到卡 → 切到别的窗口 → SSE 重连回放」
      // 就会收到一条通知，而它说的是「有一件事在等你」——用户刚刚看过它。
      var focused = true;
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => focused,
      );

      await notifier.handleItems([_card()]);
      expect(sink.sent, isEmpty);

      focused = false;
      await notifier.handleItems([_card()]);

      expect(sink.sent, isEmpty, reason: '前台已看到，切后台不该补弹');
      expect(notifier.hasSeen('conf_1'), isTrue);
    });

    test('聚焦状态是动态读的（不是构造时快照）', () async {
      var focused = false;
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => focused,
      );

      await notifier.handleItems([_card(id: 'conf_a')]);
      expect(sink.sent, hasLength(1));

      focused = true;
      await notifier.handleItems([_card(id: 'conf_b')]);
      expect(sink.sent, hasLength(1), reason: '转为聚焦后不该再发');

      focused = false;
      await notifier.handleItems([_card(id: 'conf_c')]);
      expect(sink.sent, hasLength(2), reason: '转回后台后应恢复发送');
    });
  });

  group('权限幂等', () {
    test('权限只请求一次（Android 上重复请求会反复弹框）', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(id: 'c1')]);
      await notifier.handleItems([_card(id: 'c2')]);
      await notifier.handleItems([_card(id: 'c3')]);

      expect(sink.permissionCalls, 1);
      expect(sink.sent, hasLength(3));
    });

    test('权限被拒 → 不发通知，且不再重复请求', () async {
      final sink = _RecordingSink(granted: false);
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(id: 'c1')]);
      await notifier.handleItems([_card(id: 'c2')]);

      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 1, reason: '被拒后不该每轮重问');
    });

    test('reset() 清掉权限缓存（用户可能去系统设置改了）', () async {
      final sink = _RecordingSink(granted: false);
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(id: 'c1')]);
      expect(sink.permissionCalls, 1);

      notifier.reset();
      sink.granted = true;
      await notifier.handleItems([_card(id: 'c1')]);

      expect(sink.permissionCalls, 2, reason: 'reset 后应重新请求');
      expect(sink.sent, hasLength(1));
    });

    test('reset() 清掉判重集合（换用户后同一 id 可再通知）', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card()]);
      expect(notifier.notifiedCount, 1);

      notifier.reset();
      expect(notifier.notifiedCount, 0);

      await notifier.handleItems([_card()]);
      expect(sink.sent, hasLength(2));
    });
  });

  group('通知内容', () {
    test('正文用确认卡的问题', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(question: '是否部署到生产？')]);

      expect(sink.sent.single.body, '是否部署到生产？');
    });

    test('问题为空时用兜底正文（空正文的系统通知不显示）', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(question: '')]);

      expect(sink.sent.single.body, '有一项操作等待确认');
    });

    test('payload 指向该对话（点击后要跳到对应 group）', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(groupId: 'grp_42')]);

      expect(sink.sent.single.payload, '/chat/grp_42');
    });

    test('groupId 为空时 payload 为 null（退化为「打开应用」）', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      await notifier.handleItems([_card(groupId: '')]);

      expect(sink.sent.single.payload, isNull);
    });

    test('文案可覆盖（为 i18n 留口子）', () async {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
        text: const ConfirmationNotificationText(
          title: 'Needs your confirmation',
          fallbackBody: 'An action is waiting',
        ),
      );

      await notifier.handleItems([_card(question: '')]);

      expect(sink.sent.single.title, 'Needs your confirmation');
      expect(sink.sent.single.body, 'An action is waiting');
    });
  });

  group('点击通知的接线', () {
    test('attach() 后点击通知触发导航', () async {
      final sink = _RecordingSink();
      final navigated = <String>[];
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      notifier.attach(onNavigate: navigated.add);
      sink.onSelect?.call('/chat/grp_1');

      expect(navigated, ['/chat/grp_1']);
    });

    test('未传 onNavigate 时不接线（不崩）', () {
      final sink = _RecordingSink();
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      notifier.attach();

      expect(sink.onSelect, isNull);
    });

    test('空 payload 不触发导航', () {
      final sink = _RecordingSink();
      final navigated = <String>[];
      final notifier = ConfirmationNotifier(
        sink: sink,
        isWindowFocused: () => false,
      );

      notifier.attach(onNavigate: navigated.add);
      sink.onSelect?.call(null);
      sink.onSelect?.call('');

      expect(navigated, isEmpty);
    });
  });

  group('NoopNotificationSink', () {
    test('不抛异常且权限为 false', () async {
      const sink = NoopNotificationSink();
      expect(await sink.requestPermission(), isFalse);
      await sink.show(const LocalNotification(id: 'x', title: 't', body: 'b'));
      sink.onSelect = (_) {};
    });
  });
}
