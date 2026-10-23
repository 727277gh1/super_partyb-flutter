import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 通知订阅区块测试。
///
/// ## 这个测试防的是什么
///
/// 这一块有三条**静默**的失败路径，任何一条都会让用户看到错误的账目：
/// - **按响应渲染**：新用户响应是空列表（`ListByUser` 只返回已存在的行），
///   按响应渲染会显示「暂无通知设置」——而四个模板其实都能开；
/// - **自造 key**：服务端对未知 key 是**整体 400**（不是忽略那一项），
///   传错一个就整批保存失败；
/// - **503 当成永久失败**：数据库没就绪时重试就能好，写成「失败」会让用户
///   以为设置坏了、去反复折腾。
void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    List<MiniappNotificationSubscription>? initial,
    Future<List<MiniappNotificationSubscription>> Function()? load,
    Future<List<MiniappNotificationSubscription>> Function(Map<String, int>)?
    save,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationSubscriptionsCard(
            load:
                load ??
                () async =>
                    initial ?? const <MiniappNotificationSubscription>[],
            save:
                save ??
                (accepted) async => const <MiniappNotificationSubscription>[],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  MiniappNotificationSubscription sub(String key, int quota, bool enabled) =>
      MiniappNotificationSubscription(
        templateKey: key,
        remainingQuota: quota,
        enabled: enabled,
      );

  testWidgets('新用户（响应为空）也渲染全部 4 个白名单模板', (tester) async {
    // 这是本区块最容易写错的地方：服务端只返回已存在的行，新用户一行都没有。
    // 若按响应渲染，这里会是 0 个开关。
    await pumpCard(tester, initial: const []);

    for (final key in MiniappNotificationTemplates.all) {
      expect(
        find.byKey(ValueKey('settings-notification-$key')),
        findsOneWidget,
        reason: '$key 是白名单模板，即使服务端无记录也必须渲染出来',
      );
    }
    expect(find.byType(SwitchListTile), findsNWidgets(4));
    // 无记录 = 额度 0、未开启。两个非预留 key 的副标题就是纯额度文案；
    // 两个预留 key 的副标题带「服务端暂未启用」后缀（下面单独断言）。
    expect(find.text('剩余 0 条'), findsNWidgets(2));
  });

  testWidgets('已授权的模板回显真实额度与开关状态', (tester) async {
    await pumpCard(
      tester,
      initial: [sub(MiniappNotificationTemplates.notify, 7, true)],
    );

    expect(find.text('剩余 7 条'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('settings-notification-notify')),
    );
    expect(tile.value, isTrue);
  });

  testWidgets('打开开关：只提交白名单 key，且 n > 0（累加额度）', (tester) async {
    Map<String, int>? sent;
    await pumpCard(
      tester,
      initial: [sub(MiniappNotificationTemplates.notify, 0, false)],
      save: (accepted) async {
        sent = accepted;
        return [sub(MiniappNotificationTemplates.notify, 1, true)];
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('settings-notification-notify')),
    );
    await tester.pumpAndSettle();

    expect(sent, isNotNull, reason: '必须真的发出保存请求');
    expect(sent!.keys.toList(), [MiniappNotificationTemplates.notify]);
    expect(sent![MiniappNotificationTemplates.notify], 1);
    expect(
      MiniappNotificationTemplates.isKnown(sent!.keys.first),
      isTrue,
      reason: '未知 key 会让服务端整体 400，必须挡住',
    );
  });

  testWidgets('关闭开关：n == 0（服务端归零并禁用）', (tester) async {
    Map<String, int>? sent;
    await pumpCard(
      tester,
      initial: [sub(MiniappNotificationTemplates.notify, 3, true)],
      save: (accepted) async {
        sent = accepted;
        return [sub(MiniappNotificationTemplates.notify, 0, false)];
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('settings-notification-notify')),
    );
    await tester.pumpAndSettle();

    expect(
      sent![MiniappNotificationTemplates.notify],
      0,
      reason: '0 走 ResetQuota（归零 + 禁用），不是减 1',
    );
  });

  testWidgets('保存后按服务端返回回显，不用本地乐观值', (tester) async {
    // 服务端才是权威账本：本地猜一个「1」可能与真实额度不符。
    await pumpCard(
      tester,
      initial: [sub(MiniappNotificationTemplates.notify, 0, false)],
      save: (accepted) async => [
        sub(MiniappNotificationTemplates.notify, 5, true),
      ],
    );

    await tester.tap(
      find.byKey(const ValueKey('settings-notification-notify')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('剩余 5 条'),
      findsOneWidget,
      reason: '必须回显服务端返回的额度，而不是本地 +1',
    );
  });

  testWidgets('503 显示「暂时不可用」+ 重试，而不是「失败」', (tester) async {
    await pumpCard(
      tester,
      load: () async => throw const HttpError(503, 'database unavailable'),
    );

    expect(
      find.byKey(const ValueKey('settings-notifications-unavailable')),
      findsOneWidget,
    );
    expect(find.textContaining('暂时不可用'), findsOneWidget);
    // 关键：不能渲染成错误横幅，也不能说「失败」。
    expect(
      find.byKey(const ValueKey('settings-notifications-error')),
      findsNothing,
    );
    expect(find.textContaining('失败'), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-notifications-retry')),
      findsOneWidget,
      reason: '503 重试就能好，必须给重试入口',
    );
  });

  testWidgets('503 后点重试能恢复（不是死路）', (tester) async {
    var calls = 0;
    await pumpCard(
      tester,
      load: () async {
        calls++;
        if (calls == 1) throw const HttpError(503, 'database unavailable');
        return [sub(MiniappNotificationTemplates.notify, 2, true)];
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('settings-notifications-retry')),
    );
    await tester.pumpAndSettle();

    expect(find.text('剩余 2 条'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-notifications-unavailable')),
      findsNothing,
    );
  });

  testWidgets('保存时 503 也走「暂时不可用」，不显示为失败', (tester) async {
    await pumpCard(
      tester,
      initial: [sub(MiniappNotificationTemplates.notify, 0, false)],
      save: (accepted) async =>
          throw const HttpError(503, 'database unavailable'),
    );

    await tester.tap(
      find.byKey(const ValueKey('settings-notification-notify')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-notifications-unavailable')),
      findsOneWidget,
    );
    expect(find.textContaining('失败'), findsNothing);
  });

  testWidgets('非 503 错误走错误横幅（与暂时不可用区分开）', (tester) async {
    await pumpCard(
      tester,
      load: () async => throw const HttpError(400, 'unknown template_key: x'),
    );

    expect(
      find.byKey(const ValueKey('settings-notifications-error')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-notifications-unavailable')),
      findsNothing,
      reason: '400 重试不会好，不该引导用户重试',
    );
  });

  testWidgets('预留 key 的副标题说明服务端暂未启用', (tester) async {
    // work_failed / confirmation_required 在白名单里（写入会成功），但服务端
    // 没有任何事件会以它们入队。文案若只说「剩余 N 条」，用户会以为打开就能
    // 收到该类通知。
    await pumpCard(tester, initial: const []);

    expect(
      find.textContaining('服务端暂未启用'),
      findsNWidgets(2),
      reason: 'work_failed 与 confirmation_required 都是预留 key',
    );
  });

  testWidgets('主 key（notify）的副标题不提「暂未启用」', (tester) async {
    await pumpCard(tester, initial: const []);

    final notifyTile = find.byKey(
      const ValueKey('settings-notification-notify'),
    );
    expect(
      find.descendant(of: notifyTile, matching: find.textContaining('暂未启用')),
      findsNothing,
      reason: 'notify 是唯一有生产者的 key，不该被标成未启用',
    );
  });
}
