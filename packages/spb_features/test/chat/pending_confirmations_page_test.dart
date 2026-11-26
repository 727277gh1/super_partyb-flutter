import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_features/spb_features.dart';

import '../support/contrast.dart';

/// [PendingConfirmationsPage] 的渲染与交互测试。
///
/// 页面纯 UI：数据拉取与解决都靠注入回调，不发起真实网络（无头环境）。
ChatConfirmation _confirmation({
  String id = 'cf_1',
  String groupId = 'grp_1',
  String turnId = 'turn_1',
  String kind = 'continue_suggestion',
  String status = 'pending',
  String reason = '是否继续执行任务？',
  DateTime? expiresAt,
}) => ChatConfirmation(
  id: id,
  turnId: turnId,
  groupId: groupId,
  userId: 'usr_1',
  kind: kind,
  status: status,
  createdAt: DateTime(2024, 3, 5),
  decision: {'decision': 'need_confirmation', 'reason': reason},
  expiresAt: expiresAt,
);

void main() {
  testWidgets('待确认列表渲染 group 标题与问题正文', (t) async {
    final fetched = <List<ChatConfirmation>>[];
    await t.pumpWidget(
      MaterialApp(
        home: PendingConfirmationsPage(
          fetch: () async {
            final items = [
              _confirmation(reason: '第一个确认'),
              _confirmation(id: 'cf_2', groupId: 'grp_2', reason: '第二个确认'),
            ];
            fetched.add(items);
            return items;
          },
          groupTitleOf: (gid) => gid == 'grp_1' ? '对话一' : '对话二',
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(fetched, hasLength(1));
    expect(
      find.byKey(const ValueKey('pending-confirmations-list')),
      findsOneWidget,
    );
    expect(find.text('对话一'), findsOneWidget);
    expect(find.text('对话二'), findsOneWidget);
    expect(find.text('第一个确认'), findsOneWidget);
    expect(find.text('第二个确认'), findsOneWidget);
  });

  testWidgets('点击跳转携带正确的 groupId 与 turnId', (t) async {
    String? openedGroupId;
    String? openedTurnId;
    await t.pumpWidget(
      MaterialApp(
        home: PendingConfirmationsPage(
          fetch: () async => [
            _confirmation(groupId: 'grp_x', turnId: 'turn_y'),
          ],
          groupTitleOf: (gid) => '对话 X',
          onOpenGroup: (gid, tid) {
            openedGroupId = gid;
            openedTurnId = tid;
          },
        ),
      ),
    );
    await t.pumpAndSettle();

    // 点击 group 标题行（InkWell）。
    await t.tap(find.text('对话 X'));
    await t.pump();

    expect(openedGroupId, 'grp_x');
    expect(openedTurnId, 'turn_y');
  });

  testWidgets('空态友好提示', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: PendingConfirmationsPage(
          fetch: () async => const [],
          groupTitleOf: (_) => null,
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('pending-confirmations-empty')),
      findsOneWidget,
    );
    expect(find.text('没有待确认的事项'), findsOneWidget);
  });

  testWidgets('过期状态词达到 AA 对比度（#127）', (t) async {
    // 「已过期」原先用 `scheme.outline`：那是 M3 的**边框**角色，12px 文字压在
    // 卡片上只有 4.27:1（浅色主题），卡在 WCAG AA 的 4.5 之下。
    await t.pumpWidget(
      MaterialApp(
        home: PendingConfirmationsPage(
          fetch: () async => [
            _confirmation(
              expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
            ),
          ],
          groupTitleOf: (_) => '对话一',
        ),
      ),
    );
    await t.pumpAndSettle();

    expectTextReadable(t, find.text('已过期'));
    final scheme = Theme.of(t.element(find.text('已过期'))).colorScheme;
    expect(
      t.widget<Text>(find.text('已过期')).style!.color,
      scheme.onSurfaceVariant,
      reason: '改回 outline 时对比度断言仍可能因背景不同而侥幸通过，这里直接钉角色',
    );
  });

  testWidgets('320dp / 2.0 字号：长错误文案不溢出，重试按钮可达（#126 / #128）', (t) async {
    await t.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => t.binding.setSurfaceSize(null));
    t.binding.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(t.binding.platformDispatcher.clearTextScaleFactorTestValue);

    var calls = 0;
    await t.pumpWidget(
      MaterialApp(
        home: PendingConfirmationsPage(
          fetch: () async {
            calls++;
            throw const NetworkError(
              '待确认列表拉取失败（https://dever.example.com/pba/me/pending-confirmations）：'
              'connection timed out after 12s。请检查网络后重试；如果仍然失败，'
              '请联系管理员并提供上面这行完整提示。',
            );
          },
          groupTitleOf: (_) => null,
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(t.takeException(), isNull, reason: '溢出是硬失败');
    // 正文级文案不截断：靠滚动而不是 `maxLines`（字号也不许被 clamp，§6.80）。
    expect(find.textContaining('connection timed out'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pending-confirmations-error')),
      findsOneWidget,
    );

    await t.scrollUntilVisible(
      find.byKey(const ValueKey('pending-confirmations-retry')),
      120,
    );
    await t.tap(find.byKey(const ValueKey('pending-confirmations-retry')));
    await t.pumpAndSettle();
    expect(calls, 2, reason: '滚下去点得到，才算「操作可达」');
  });

  testWidgets('加载失败：用共享 ErrorState，不泄露运行时类型名（#128）', (t) async {
    var calls = 0;
    await t.pumpWidget(
      MaterialApp(
        home: PendingConfirmationsPage(
          fetch: () async {
            calls++;
            throw const NetworkError('待确认列表拉取失败');
          },
          groupTitleOf: (_) => null,
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('pending-confirmations-error')),
      findsOneWidget,
    );
    expect(find.text('待确认列表拉取失败'), findsOneWidget);
    expect(find.textContaining('NetworkError'), findsNothing);

    // 重试按钮的 key 由页面透传（收敛到共享组件后仍可定位）。
    await t.tap(find.byKey(const ValueKey('pending-confirmations-retry')));
    await t.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('解决确认调用 onResolve 并从列表移除', (t) async {
    final resolved = <String>[];
    await t.pumpWidget(
      MaterialApp(
        home: PendingConfirmationsPage(
          fetch: () async => [_confirmation()],
          groupTitleOf: (_) => '对话一',
          onResolve: (c, action) async {
            resolved.add('${c.id}:$action');
          },
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('第一个确认')..last, findsNothing);
    expect(find.text('是否继续执行任务？'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('pending-confirmation-approve')));
    await t.pumpAndSettle();

    expect(resolved, ['cf_1:approve']);
    // 解决后从列表移除。
    expect(
      find.byKey(const ValueKey('pending-confirmations-empty')),
      findsOneWidget,
    );
  });

  testWidgets('即将过期的项显示警告提示', (t) async {
    final soon = DateTime.now().add(const Duration(minutes: 5));
    await t.pumpWidget(
      MaterialApp(
        home: PendingConfirmationsPage(
          fetch: () async => [_confirmation(expiresAt: soon)],
          groupTitleOf: (_) => '对话一',
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('即将过期'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
  });
}
