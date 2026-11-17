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

  /// 确认卡的固定标题（历史两条入口——SSE 事件与卡片列表——都不带标题）。
  ///
  /// 新入口 [handleNotices] 用服务端下发的 `Notice.title`，不再读这里；
  /// 保留它是为了不改变既有 SSE/轮询路径的行为。
  static const _defaultTitle = '需要你确认';

  /// 卡片失效后追加的标记。
  ///
  /// 语义：**通知本身不过期**，过期的是卡片。所以不跳过、不取消，只把正文
  /// 降级为「已失效」——用户需要知道「刚才发生过什么」，而不是什么都看不到。
  static const _expiredSuffix = '（已失效，仅作记录）';

  /// 用 `/me/notices` 的**持久通知**驱动本地通知。
  ///
  /// ## 与 [reconcile] 的关键差别：通知不过期
  ///
  /// 确认卡 10 分钟后转 `expired` 并从卡片列表里消失，所以走卡片列表的轮询
  /// 在 15 分钟周期下永远拉到已过期的卡（实现正确地跳过它，于是每次都白跑）。
  /// notice 是持久事实：卡片过期后它仍然在，**必须弹**——它回答的是「刚才发生过
  /// 什么」，不是「现在还能不能点」。
  ///
  /// 因此这里**不把 `expires_at` 传给本地通知**（传了会被 [_handle] 当成过期
  /// 而 cancel），只把正文降级为带 [_expiredSuffix] 的版本。
  ///
  /// ## 已读即取消
  ///
  /// `readAt != null` 映射为 `resolved`：用户在另一台设备上看过了，本地那条
  /// 通知就该撤销（已读是用户级、跨设备的）。
  Future<List<LocalNotification>> handleNotices(
    Iterable<Notice> notices, {
    required bool focused,
  }) => _handle([
    for (final n in notices)
      if (n.id.isNotEmpty)
        _Notice(
          id: n.id,
          groupId: n.deepLinkGroupId ?? '',
          title: n.title.isEmpty ? null : n.title,
          body: _noticeBody(n),
          resolved: n.isRead,
          neverExpires: true,
        ),
  ], focused: focused);

  /// 通知正文：卡片已失效的确认卡降级为「已失效」而不是被跳过。
  String _noticeBody(Notice n) {
    if (n.kind != 'confirmation_required') return n.body;
    if (!n.isCardExpiredAt(clock())) return n.body;
    final body = n.body.trim();
    return body.isEmpty ? _expiredSuffix : '$body$_expiredSuffix';
  }

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
      // 升级窗口：旧路径（卡片列表）写下的 receipt **带非空 `expiresAt`**，而
      // 本路径（`/me/notices`）写的一律是 `null`。两者因此可区分：带 expire 的
      // receipt 属于旧路径，对持久通知没有裁决权——它记录的「已处理」是卡片的
      // 生命周期，不是「用户看过这条通知」。
      //
      // 不忽略的话，下面的 `previous != null` 分支会把这条通知记成「已弹过」
      // 然后 `continue`，用户升级后一条都收不到（静默失效，无日志）。
      final recorded = receipts[notice.id];
      final previous = notice.neverExpires && recorded?.expiresAt != null
          ? null
          : recorded;
      final expiry = notice.neverExpires
          ? null
          : (notice.expiresAt ?? previous?.expiresAt);
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
        title: notice.title ?? _defaultTitle,
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
    this.title,
    this.expiresAt,
    this.neverExpires = false,
  });
  final String id;
  final String groupId;
  final String body;

  /// 通知标题。null 时回退到确认卡的固定文案（历史两条入口都没有标题）。
  final String? title;
  final bool resolved;
  final DateTime? expiresAt;

  /// 永不因过期而被跳过/撤销。
  ///
  /// 持久通知用它：`expires_at` 描述的是**卡片**还能不能点，不是**通知**该不该留。
  /// 它同时覆盖升级窗口的两条静默失效路径（[_handle] 里对应两处）：
  ///
  /// 1. 回退到 `previous?.expiresAt` —— 旧 receipt 带着过去的 expiresAt，不屏蔽
  ///    就会被当成「已过期」直接跳过；
  /// 2. `previous != null` 的判重分支 —— 旧 receipt 属于卡片路径，却会让这条通知
  ///    被记成「已弹过」而永不发出。带非空 `expiresAt` 的 receipt 因此被忽略。
  final bool neverExpires;
}
