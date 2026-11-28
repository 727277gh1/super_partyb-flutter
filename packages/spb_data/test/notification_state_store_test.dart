import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

void main() {
  late Directory directory;
  late NotificationStateStore first;
  late NotificationStateStore second;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('spb-notifications-');
    Future<File> resolve() async => File('${directory.path}/state.db');
    first = NotificationStateStore.open(resolve);
    second = NotificationStateStore.open(resolve);
    // 迁移先完成；接下来的竞争发生在真正独立的 SQLite 连接之间。
    await first.generation();
    await second.generation();
  });
  tearDown(() async {
    await first.close();
    await second.close();
    await directory.delete(recursive: true);
  });

  test('两个 engine 同时通知同一卡只发送一次，记录跨开库保留', () async {
    final shown = <String>[];
    ConfirmationNotificationInbox inbox(NotificationStateStore state) =>
        ConfirmationNotificationInbox(
          store: state,
          show: (n) async {
            shown.add(n.id);
            return true;
          },
          cancel: (_) async {},
          canNotify: () async => true,
        );
    final item = ConfirmationItem(
      id: 'e',
      createdAt: DateTime.now(),
      question: '确认',
      confirmationId: 'c',
      groupId: 'g',
    );
    await Future.wait([
      inbox(first).handleItems([item], focused: false),
      inbox(second).handleItems([item], focused: false),
    ]);
    expect(shown, ['c']);
    expect((await second.loadReceipts())['c']!.shown, isTrue);
  });

  test('通知版本跨 engine 持久化，同 ID 更新重新发送而已读可以撤销', () async {
    final shown = <String>[];
    final cancelled = <String>[];
    ConfirmationNotificationInbox inbox(NotificationStateStore state) =>
        ConfirmationNotificationInbox(
          store: state,
          show: (n) async {
            shown.add(n.id);
            return true;
          },
          cancel: (id) async => cancelled.add(id),
          canNotify: () async => true,
        );
    final at = DateTime.utc(2026, 11, 20);
    Notice notice(int revision, {bool read = false}) => Notice(
      id: 'n1',
      kind: 'turn_completed',
      severity: 'info',
      title: '完成',
      body: '请查看',
      createdAt: at,
      updatedAt: at.add(Duration(seconds: revision)),
      readAt: read ? at : null,
    );
    await Future.wait([
      inbox(first).handleNotices([notice(1)], focused: false),
      inbox(second).handleNotices([notice(1)], focused: false),
    ]);
    expect(shown, ['n1']);
    expect((await second.loadReceipts())['n1']!.revision, notice(1).revision);
    await inbox(second).handleNotices([notice(2)], focused: false);
    await inbox(first).handleNotices([notice(2)], focused: false);
    expect(shown, ['n1', 'n1']);
    await inbox(first).handleNotices([notice(3, read: true)], focused: false);
    expect(cancelled, ['n1']);
  });

  test('两个 manager 刷新不并发，登出等待在途刷新后清空凭证和通知', () async {
    final raw = InMemoryTokenStore();
    await raw.write(
      const StoredTokens(accessToken: 'old', refreshToken: 'refresh'),
    );
    final cancelled = <String>[];
    CoordinatedTokenStore tokenStore(NotificationStateStore state) =>
        CoordinatedTokenStore(
          tokens: raw,
          state: state,
          cancelNotification: (id) async {
            cancelled.add(id);
          },
        );
    final entered = Completer<void>();
    final release = Completer<void>();
    var active = 0;
    var maximum = 0;
    Future<StoredTokens?> refresh(StoredTokens previous) async {
      active++;
      if (active > maximum) maximum = active;
      if (!entered.isCompleted) entered.complete();
      await release.future;
      active--;
      return const StoredTokens(accessToken: 'new', refreshToken: 'rotated');
    }

    await first.exclusive(
      () => first.saveReceipts({'c': const ConfirmationReceipt(shown: true)}),
    );
    final a = SessionManager(store: tokenStore(first), refresher: refresh);
    final b = SessionManager(store: tokenStore(second), refresher: refresh);
    final pending = a.refreshWithOutcome();
    await entered.future;
    final other = b.refreshWithOutcome();
    final logout = b.logout();
    release.complete();
    await Future.wait([pending, other, logout]);
    expect(maximum, 1);
    expect(await raw.read(), isNull);
    expect(cancelled, ['c']);
    expect(await second.generation(), 1);
    expect(await first.loadReceipts(), isEmpty);
  });

  test('上次成功时刻跨 engine 可见，且失败不写（不能把旧的时刻当「刚跑过」）', () async {
    expect(await first.lastCheckAt(), isNull);
    final at = DateTime.utc(2026, 11, 16, 9, 32);
    await first.markChecked(at);
    expect(await second.lastCheckAt(), at);
  });

  test('最近一次结局跨 engine 可见，且失败/跳过不擦掉上次成功时刻', () async {
    final ok = DateTime.utc(2026, 11, 16, 9, 32);
    await first.recordBackgroundCheck(
      BackgroundCheckResult(
        outcome: BackgroundCheckOutcome.ok,
        at: ok,
        unread: 2,
        fetched: 5,
        shown: 1,
      ),
    );
    var report = await second.backgroundCheckReport();
    expect(report.lastSuccessAt, ok);
    expect(report.last!.outcome, BackgroundCheckOutcome.ok);
    expect(report.last!.fetched, 5);
    expect(report.last!.shown, 1);

    // 失败：时刻保留（它确实成功过），但「最近一次」必须是失败。
    final failedAt = DateTime.utc(2026, 11, 16, 10, 0);
    await second.recordBackgroundCheck(
      BackgroundCheckResult(
        outcome: BackgroundCheckOutcome.failed,
        at: failedAt,
        failure: BackgroundCheckFailure.request,
        error: 'DioException [connection timeout]',
      ),
    );
    report = await first.backgroundCheckReport();
    expect(report.lastSuccessAt, ok);
    expect(report.last!.outcome, BackgroundCheckOutcome.failed);
    expect(report.last!.failure, BackgroundCheckFailure.request);
    expect(report.last!.error, contains('timeout'));

    // 跳过：同理，且要能读出「为什么没弹」。
    await first.recordBackgroundCheck(
      BackgroundCheckResult(
        outcome: BackgroundCheckOutcome.skipped,
        at: DateTime.utc(2026, 11, 16, 10, 15),
        skip: BackgroundCheckSkip.noPermission,
      ),
    );
    report = await second.backgroundCheckReport();
    expect(report.lastSuccessAt, ok);
    expect(report.last!.skip, BackgroundCheckSkip.noPermission);
  });

  test('升级前的库没有最近一次记录时读出 null（而不是抛）', () async {
    final report = await first.backgroundCheckReport();
    expect(report.lastSuccessAt, isNull);
    expect(report.last, isNull);
  });

  test('读凭证不占互斥锁：刷新持锁期间仍能读', () async {
    // 若 `read` 走 `exclusive`，每个 HTTP 请求都要做一次 SQLite 写事务，
    // 而且会排在另一个 engine 的刷新（跨网络）后面。这里用一个持锁不放的
    // 动作把锁占住：`read` 必须仍能立即返回。
    final raw = InMemoryTokenStore();
    await raw.write(const StoredTokens(accessToken: 'a'));
    final tokens = CoordinatedTokenStore(
      tokens: raw,
      state: first,
      cancelNotification: (_) async {},
    );
    final holding = Completer<void>();
    final release = Completer<void>();
    final holder = first.exclusive(() async {
      holding.complete();
      await release.future;
    });
    await holding.future;
    expect(
      (await tokens.read().timeout(const Duration(seconds: 2)))?.accessToken,
      'a',
    );
    release.complete();
    await holder;
  });

  test('换账号递增会话版本，refresh 本身不重置通知判重', () async {
    final raw = InMemoryTokenStore();
    final tokens = CoordinatedTokenStore(
      tokens: raw,
      state: first,
      cancelNotification: (_) async {},
    );
    await tokens.write(const StoredTokens(accessToken: 'a', refreshToken: 'r'));
    final generation = await first.generation();
    await first.saveReceipts({'c': const ConfirmationReceipt(shown: false)});
    final manager = SessionManager(
      store: tokens,
      refresher: (_) async =>
          const StoredTokens(accessToken: 'b', refreshToken: 'r2'),
    );
    await manager.refreshWithOutcome();
    expect(await first.generation(), generation);
    expect(await second.loadReceipts(), contains('c'));
    await tokens.write(const StoredTokens(accessToken: 'another-user'));
    expect(await first.generation(), generation + 1);
    expect(await second.loadReceipts(), isEmpty);
  });
}
