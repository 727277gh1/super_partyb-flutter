import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/spb_features.dart';

/// `MessageComposer` 的「清空上下文」入口测试。
///
/// ## 为什么这条入口单独测
///
/// 它是本端**唯一**不可撤销的动作：归档旧绑定后，AI 从此不记得之前的对话
/// 内容。所以它必须满足三条：
/// 1. 未接线时**不出现**（与 `onFlush` 同一约定：可空 = 不显示）；
/// 2. 点了先问一句，取消就**什么都不发生**（一次网络往返都不该发）；
/// 3. 执行期间禁用，防连点。
///
/// ## 为什么叫「清空上下文」而不是「新对话」
///
/// 它保留 group（标题、交付物、任务清单、工作区文件全在），只清 pigo 的
/// session。「新对话」会被读成「新建一个对话」——小程序里的「新建」确实是建
/// group，用户已经建立了这个预期。详见 docs/design-decisions/chat.md §6.66。
void main() {
  /// 把输入栏放进最小可用的 MaterialApp。
  Future<void> pumpComposer(
    WidgetTester tester, {
    Future<void> Function()? onNewSession,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              MessageComposer(onSubmit: (_) {}, onNewSession: onNewSession),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('清空上下文', () {
    testWidgets('未接线时不显示入口', (tester) async {
      await pumpComposer(tester);

      expect(
        find.byKey(const ValueKey('composer-new-session')),
        findsNothing,
        reason: 'onNewSession 为 null 时不显示——与 onFlush 同一约定',
      );
    });

    testWidgets('点按钮先弹确认框，不直接执行', (tester) async {
      var calls = 0;
      await pumpComposer(tester, onNewSession: () async => calls++);

      await tester.tap(find.byKey(const ValueKey('composer-new-session')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('new-session-confirm')), findsOneWidget);
      expect(calls, 0, reason: '确认之前不得发起请求');
      // 文案必须写清「什么保留、什么失去」。
      expect(find.textContaining('都会保留'), findsOneWidget);
      expect(find.textContaining('不再记得'), findsOneWidget);
    });

    testWidgets('取消 → 什么都不发生', (tester) async {
      var calls = 0;
      await pumpComposer(tester, onNewSession: () async => calls++);

      await tester.tap(find.byKey(const ValueKey('composer-new-session')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('new-session-confirm-cancel')),
      );
      await tester.pumpAndSettle();

      expect(calls, 0, reason: '取消就是取消：不该发任何请求');
      expect(find.byKey(const ValueKey('new-session-confirm')), findsNothing);
    });

    testWidgets('确认 → 执行一次', (tester) async {
      var calls = 0;
      await pumpComposer(tester, onNewSession: () async => calls++);

      await tester.tap(find.byKey(const ValueKey('composer-new-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-session-confirm-ok')));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.byKey(const ValueKey('new-session-confirm')), findsNothing);
    });

    testWidgets('执行期间按钮禁用（防连点重复归档）', (tester) async {
      final gate = Completer<void>();
      await pumpComposer(tester, onNewSession: () => gate.future);

      await tester.tap(find.byKey(const ValueKey('composer-new-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-session-confirm-ok')));
      await tester.pump();

      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('composer-new-session')),
      );
      expect(button.onPressed, isNull, reason: '在途时必须禁用');

      gate.complete();
      await tester.pumpAndSettle();

      final after = tester.widget<IconButton>(
        find.byKey(const ValueKey('composer-new-session')),
      );
      expect(after.onPressed, isNotNull, reason: '完成后必须复位，否则永久禁用');
    });
  });
}
