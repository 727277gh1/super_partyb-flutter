import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

class _Store implements ConfirmationReceiptStore {
  Map<String, ConfirmationReceipt> data = {};
  @override
  Future<T> exclusive<T>(Future<T> Function() action) => action();
  @override
  Future<Map<String, ConfirmationReceipt>> loadReceipts() async => {...data};
  @override
  Future<void> saveReceipts(Map<String, ConfirmationReceipt> receipts) async {
    data = {...receipts};
  }
}

void main() {
  final now = DateTime.utc(2026, 11, 17);
  late _Store store;
  late List<LocalNotification> shown;
  late List<String> cancelled;
  late bool permitted;
  late bool successful;
  late DateTime clock;

  ChatConfirmation card({
    String id = 'c1',
    String userId = 'u1',
    String status = 'pending',
    DateTime? expiresAt,
  }) => ChatConfirmation(
    id: id,
    turnId: 't1',
    groupId: 'g1',
    userId: userId,
    kind: 'confirm',
    status: status,
    createdAt: now,
    expiresAt: expiresAt ?? now.add(const Duration(minutes: 10)),
  );
  ConfirmationNotificationInbox inbox() => ConfirmationNotificationInbox(
    store: store,
    show: (n) async {
      if (successful) shown.add(n);
      return successful;
    },
    cancel: (id) async {
      cancelled.add(id);
    },
    canNotify: () async => permitted,
    clock: () => clock,
  );
  Future<void> poll(
    List<ChatConfirmation> cards, {
    bool complete = true,
    bool focused = false,
  }) async {
    await inbox().reconcile(
      cards,
      userId: 'u1',
      focused: focused,
      complete: complete,
    );
  }


  Notice notice({
    String id = 'n1',
    String kind = 'confirmation_required',
    String title = '需要你确认',
    String body = '需要确认是否继续重试',
    Map<String, String> data = const {},
    DateTime? readAt,
  }) => Notice(
    id: id,
    kind: kind,
    severity: 'warning',
    title: title,
    body: body,
    data: data,
    groupId: 'g1',
    createdAt: now,
    readAt: readAt,
  );
  Future<void> pollNotices(List<Notice> items, {bool focused = false}) =>
      inbox().handleNotices(items, focused: focused);

  setUp(() {
    store = _Store();
    shown = [];
    cancelled = [];
    permitted = true;
    successful = true;
    clock = now;
  });

  test('重建后台判定器不重复通知，保留点击路由和有效期', () async {
    await poll([card()]);
    await poll([card()]);
    expect(shown, hasLength(1));
    expect(shown.single.payload, '/chat/g1');
    expect(shown.single.expiresAt, card().expiresAt);
  });

  test('前台 SSE 看过的卡不会被后台补弹，后台发过的也不会被 SSE 重发', () async {
    final item = ConfirmationItem(
      id: 'e1',
      createdAt: now,
      question: '确认？',
      confirmationId: 'c1',
      groupId: 'g1',
    );
    await inbox().handleItems([item], focused: true);
    await poll([card()]);
    expect(shown, isEmpty);
    await poll([card(id: 'c2')], complete: false);
    await inbox().handleItems([
      ConfirmationItem(
        id: 'e2',
        createdAt: now,
        question: '确认？',
        confirmationId: 'c2',
        groupId: 'g1',
      ),
    ], focused: false);
    expect(shown.map((n) => n.id), ['c2']);
  });

  test('已过期、已解决或其他账号的卡不通知', () async {
    await poll([
      card(expiresAt: now),
      card(id: 'resolved', status: 'resolved'),
      card(id: 'other', userId: 'u2'),
    ]);
    expect(shown, isEmpty);
  });

  test('权限拒绝或发送失败不消耗判重，恢复后可通知', () async {
    permitted = false;
    await poll([card()]);
    expect(store.data, isEmpty);
    permitted = true;
    successful = false;
    await poll([card()]);
    expect(store.data, isEmpty);
    successful = true;
    await poll([card()]);
    expect(shown, hasLength(1));
  });

  test('截断列表不撤销缺席项，完整列表可以撤销且不重复撤销', () async {
    await poll([card()]);
    await poll([], complete: false);
    expect(cancelled, isEmpty);
    await poll([]);
    await poll([]);
    expect(cancelled, ['c1']);
  });

  test('即使列表截断也撤销已知过期的通知', () async {
    await poll([card()]);
    clock = now.add(const Duration(minutes: 11));
    await poll([], complete: false);
    expect(cancelled, ['c1']);
  });

  test('SSE 解决可撤销此前由后台发出的通知', () async {
    await poll([card()]);
    await inbox().handleItems([
      ConfirmationItem(
        id: 'e1',
        createdAt: now,
        question: '确认？',
        resolved: true,
        confirmationId: 'c1',
        groupId: 'g1',
      ),
    ], focused: true);
    expect(cancelled, ['c1']);
  });

  // ---------- handleNotices：/me/notices 驱动的持久通知 ----------

  test('通知标题来自服务端，不再硬编码', () async {
    await pollNotices([notice(title: '有任务等你确认')]);
    expect(shown, hasLength(1));
    expect(shown.single.title, '有任务等你确认');
  });

  test('卡片已过期仍然通知，正文降级为已失效', () async {
    // 这是 #187 的核心价值：卡片 10 分钟后消失，notice 不会。
    clock = now.add(const Duration(hours: 2));
    await pollNotices([
      notice(data: {'expires_at': now.add(const Duration(minutes: 10)).toIso8601String()}),
    ]);
    expect(shown, hasLength(1));
    expect(shown.single.body, contains('已失效'));
    // 关键：不能把 expiresAt 传给本地通知，否则 _handle 会把它当成过期而跳过。
    expect(shown.single.expiresAt, isNull);
  });

  test('升级窗口：旧 receipt 带过去的 expiresAt 不能吞掉新通知', () async {
    // 旧路径（卡片列表）写下的 receipt 带已过期的 expiresAt。
    store.data['n1'] = ConfirmationReceipt(
      shown: false,
      expiresAt: now.subtract(const Duration(minutes: 1)),
    );
    await pollNotices([notice()]);
    expect(shown.map((n) => n.id), ['n1']);
  });

  test('已读（别端 ack）撤销本地通知且不重复弹', () async {
    await pollNotices([notice()]);
    expect(shown, hasLength(1));
    await pollNotices([notice(readAt: now)]);
    expect(cancelled, ['n1']);
  });

  test('同一通知只弹一次', () async {
    await pollNotices([notice()]);
    await pollNotices([notice()]);
    expect(shown, hasLength(1));
  });

  test('未知 kind 也通知，不抛异常', () async {
    await pollNotices([notice(kind: 'turn_completed', title: '任务完成', body: '好了')]);
    expect(shown, hasLength(1));
    expect(shown.single.title, '任务完成');
  });
}
