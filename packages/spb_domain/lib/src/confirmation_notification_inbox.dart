import 'package:spb_models/spb_models.dart';

import 'confirmation_notifier.dart';
import 'conversation_item.dart';
import 'notifications.dart';

/// 只保存判重和撤销所需信息，不落盘通知正文。
class ConfirmationReceipt {
  const ConfirmationReceipt({required this.shown, this.expiresAt});

  final bool shown;
  final DateTime? expiresAt;
}

abstract interface class ConfirmationReceiptStore {
  /// 前台 SSE 与后台轮询必须共享同一个数据库锁。
  Future<T> exclusive<T>(Future<T> Function() action);
  Future<Map<String, ConfirmationReceipt>> loadReceipts();
  Future<void> saveReceipts(Map<String, ConfirmationReceipt> receipts);
}

/// 前后台共用的持久化通知判定，保留「前台看到过就不再补弹」语义。
class ConfirmationNotificationInbox {
  ConfirmationNotificationInbox({
    required this.store,
    required this.show,
    required this.cancel,
    required this.canNotify,
    this.clock = DateTime.now,
  });

  final ConfirmationReceiptStore store;
  final Future<bool> Function(LocalNotification) show;
  final Future<void> Function(String) cancel;
  final Future<bool> Function() canNotify;
  final DateTime Function() clock;

  Future<List<LocalNotification>> handleItems(
    Iterable<ConversationItem> items, {
    required bool focused,
  }) => _handle([
    for (final item in items)
      if (item is ConfirmationItem)
        _Notice(
          id: item.confirmationId,
          groupId: item.groupId,
          body: item.question,
          resolved: item.resolved,
        ),
  ], focused: focused);

  Future<List<LocalNotification>> reconcile(
    List<ChatConfirmation> cards, {
    required String userId,
    required bool focused,
    required bool complete,
  }) => _handle(
    [
      for (final card in cards)
        if (card.userId == userId)
          _Notice(
            id: card.id,
            groupId: card.groupId,
            body: card.reason,
            resolved: !card.isPending,
            expiresAt: card.expiresAt,
          ),
    ],
    focused: focused,
    complete: complete,
  );

  Future<List<LocalNotification>> _handle(
    List<_Notice> notices, {
    required bool focused,
    bool complete = false,
  }) => store.exclusive(() async {
    final receipts = await store.loadReceipts();
    final now = clock();
    final present = notices.map((n) => n.id).toSet();
    for (final entry in receipts.entries.toList()) {
      final expired = entry.value.expiresAt?.isAfter(now) == false;
      // 满页不能证明卡不存在，只有完整快照才能据「缺席」撤销。
      if (entry.value.shown &&
          (expired || (complete && !present.contains(entry.key)))) {
        await cancel(entry.key);
        receipts[entry.key] = ConfirmationReceipt(
          shown: false,
          expiresAt: entry.value.expiresAt,
        );
      }
    }

    final sent = <LocalNotification>[];
    for (final notice in notices) {
      if (notice.id.isEmpty) continue;
      final previous = receipts[notice.id];
      final expiry = notice.expiresAt ?? previous?.expiresAt;
      if (notice.resolved || expiry?.isAfter(now) == false) {
        if (previous?.shown == true) await cancel(notice.id);
        receipts[notice.id] = ConfirmationReceipt(
          shown: false,
          expiresAt: expiry,
        );
        continue;
      }
      if (previous != null || focused) {
        receipts[notice.id] = ConfirmationReceipt(
          shown: previous?.shown ?? false,
          expiresAt: expiry,
        );
        continue;
      }
      // 权限可能已被系统设置撤销；后台只能查询，不能弹权限框。
      if (!await canNotify()) continue;
      final notification = LocalNotification(
        id: notice.id,
        title: '需要你确认',
        body: notice.body.isEmpty ? '有一项操作等待确认' : notice.body,
        payload: notice.groupId.isEmpty
            ? null
            : confirmationNotificationPayload(notice.groupId),
        expiresAt: expiry,
      );
      if (await show(notification)) {
        receipts[notice.id] = ConfirmationReceipt(
          shown: true,
          expiresAt: expiry,
        );
        sent.add(notification);
      }
    }
    // 保留活动通知，历史记录按插入顺序有界淘汰。
    for (final id in receipts.keys.toList()) {
      if (receipts.length <= ConfirmationNotifier.notifiedIdsCapacity) break;
      if (!receipts[id]!.shown) receipts.remove(id);
    }
    await store.saveReceipts(receipts);
    return sent;
  });
}

class _Notice {
  const _Notice({
    required this.id,
    required this.groupId,
    required this.body,
    required this.resolved,
    this.expiresAt,
  });
  final String id;
  final String groupId;
  final String body;
  final bool resolved;
  final DateTime? expiresAt;
}
