import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';

/// 扫码登录确认页的行为契约。
///
/// ## 这个页面防的是什么
///
/// 它是整条扫码登录链路上**唯一的**人工判断点（RFC 8628 §5.2）。三类错误都是
/// 静默的：
///
/// - 不显示「发起设备」→ 用户没有可否定的信号，钓鱼链路无声成立；
/// - 没有「不是我」按钮 → 用户只能二选一（确认 / 杀进程）；
/// - 预览失败时仍显示「确认」按钮 → 用户会对一个未知会话点确认。
void main() {
  QrLoginPreview preview({
    QrLoginStatus status = QrLoginStatus.pending,
    String device = '43.174.246.24 · Windows · Chrome',
    String account = 'Jim',
    int? expiresIn = 287,
  }) => QrLoginPreview(
    status: status,
    device: device,
    accountName: account,
    expiresInSeconds: expiresIn,
  );

  Future<void> pump(
    WidgetTester tester, {
    required Future<QrLoginPreview> Function() onLoad,
    Future<QrLoginStatus> Function()? onConfirm,
    Future<QrLoginStatus> Function()? onDeny,
    void Function(QrLoginStatus)? onDone,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QrLoginConfirmPage(
          scene: 'scene-1',
          onLoad: onLoad,
          onConfirm: onConfirm ?? () async => QrLoginStatus.confirmed,
          onDeny: onDeny ?? () async => QrLoginStatus.denied,
          onDone: onDone,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('待确认', () {
    testWidgets('展示发起设备、账号与有效期（反钓鱼的唯一依据）', (tester) async {
      await pump(tester, onLoad: () async => preview());

      expect(find.text('是否在这台设备上登录？'), findsOneWidget);
      expect(find.text('43.174.246.24 · Windows · Chrome'), findsOneWidget);
      expect(find.text('Jim'), findsOneWidget);
      expect(find.textContaining('4 分 47 秒'), findsOneWidget);
      expect(find.text('确认登录'), findsOneWidget);
      expect(find.text('不是我，取消'), findsOneWidget);
    });

    testWidgets('确认 → 调用 onConfirm、展示已确认并回调 onDone', (tester) async {
      var confirmCalls = 0;
      QrLoginStatus? doneWith;
      await pump(
        tester,
        onLoad: () async => preview(),
        onConfirm: () async {
          confirmCalls++;
          return QrLoginStatus.confirmed;
        },
        onDone: (status) => doneWith = status,
      );

      await tester.tap(find.text('确认登录'));
      await tester.pumpAndSettle();

      expect(confirmCalls, 1);
      expect(find.text('已确认登录'), findsOneWidget);
      expect(doneWith, QrLoginStatus.confirmed);
      // 结果态不该再给「确认」按钮（重复点必然 409）。
      expect(find.text('确认登录'), findsNothing);
    });

    testWidgets('「不是我」→ 调用 onDeny 并展示已拒绝 + 改密提醒', (tester) async {
      var denyCalls = 0;
      await pump(
        tester,
        onLoad: () async => preview(),
        onDeny: () async {
          denyCalls++;
          return QrLoginStatus.denied;
        },
      );

      await tester.tap(find.text('不是我，取消'));
      await tester.pumpAndSettle();

      expect(denyCalls, 1);
      expect(find.text('已拒绝登录'), findsOneWidget);
      expect(find.textContaining('修改密码'), findsOneWidget);
    });

    testWidgets('确认中点按钮被禁用（避免重复提交）', (tester) async {
      final completer = Completer<QrLoginStatus>();
      await pump(
        tester,
        onLoad: () async => preview(),
        onConfirm: () => completer.future,
      );

      await tester.tap(find.text('确认登录'));
      await tester.pump();

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      final cancel = tester.widget<TextButton>(find.byType(TextButton));
      expect(cancel.onPressed, isNull);

      completer.complete(QrLoginStatus.confirmed);
      await tester.pumpAndSettle();
    });
  });

  group('异常与终态', () {
    testWidgets('预览失败 → 展示可读原因 + 重试，不给确认按钮', (tester) async {
      var loads = 0;
      await pump(
        tester,
        onLoad: () async {
          loads++;
          if (loads == 1) {
            throw const AuthError('二维码已过期，请在电脑/浏览器上刷新后重试');
          }
          return preview();
        },
      );

      expect(find.textContaining('二维码已过期'), findsOneWidget);
      expect(find.text('确认登录'), findsNothing);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('确认登录'), findsOneWidget);
    });

    testWidgets('会话已被确认（重复点开同一条深链）→ 直接展示结果', (tester) async {
      await pump(
        tester,
        onLoad: () async => preview(status: QrLoginStatus.confirmed),
      );

      expect(find.text('已确认登录'), findsOneWidget);
      expect(find.text('确认登录'), findsNothing);
    });

    testWidgets('会话已被拒绝 → 直接展示结果', (tester) async {
      await pump(
        tester,
        onLoad: () async => preview(status: QrLoginStatus.denied),
      );

      expect(find.text('已拒绝登录'), findsOneWidget);
    });

    testWidgets('确认失败（409 已被他人确认）→ 展示原因而非静默', (tester) async {
      await pump(
        tester,
        onLoad: () async => preview(),
        onConfirm: () async => throw const AuthError('这次登录已被其他账号确认，请重新出码'),
      );

      await tester.tap(find.text('确认登录'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已被其他账号确认'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });
}
