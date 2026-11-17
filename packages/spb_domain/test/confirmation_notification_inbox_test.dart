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
}
