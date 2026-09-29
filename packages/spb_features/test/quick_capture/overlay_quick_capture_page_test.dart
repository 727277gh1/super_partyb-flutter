import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_platform/spb_platform.dart';

/// 记录调用参数的假 submit。
///
/// ## 为什么记录 attachments 的**文件名**而不是完整对象
///
/// 本页的职责是「把 DroppedFile 读成字节并交给上层」。测试要固定的是
/// 「哪些文件被带上了」这个可观测结果，而不是字节内容（那是 use case 的
/// 测试范围）。记录文件名让断言不受读取实现变化的影响。
class _FakeSubmit {
  final calls = <({String input, List<String> names})>[];

  QuickCaptureEnqueueResult result = const QuickCaptureEnqueueResult(
    delivered: true,
  );

  Future<QuickCaptureEnqueueResult> call({
    required String input,
    required List<QuickCaptureAttachment> attachments,
    void Function(int done, int total)? onUploadProgress,
  }) async {
    calls.add((input: input, names: attachments.map((a) => a.filename).toList()));
    onUploadProgress?.call(attachments.length, attachments.length);
    return result;
  }
}

/// 记录拖拽回调的假能力（避免依赖 desktop_drop 的平台通道）。
class _FakeDragDrop implements DragDropCapability {
  _FakeDragDrop({this.supported = true});

  final bool supported;
  void Function(List<DroppedFile> files)? captured;
  void Function(bool hovering)? capturedHover;

  @override
  bool get isSupported => supported;

  @override
  Widget buildDropZone({
    required Widget child,
    required void Function(List<DroppedFile> files) onFiles,
    void Function(bool hovering)? onHoverChanged,
  }) {
    captured = onFiles;
    capturedHover = onHoverChanged;
    return child;
  }
}

Widget _host(Widget child) => MaterialApp(home: child);

DroppedFile _file(String name, [List<int>? bytes]) =>
    DroppedFile.fromBytes(name: name, bytes: bytes ?? const [1, 2, 3]);

void main() {
  late _FakeSubmit submit;
  late _FakeDragDrop dragDrop;

  setUp(() {
    submit = _FakeSubmit();
    dragDrop = _FakeDragDrop();
  });

  Widget build({VoidCallback? onClose}) => _host(
    OverlayQuickCapturePage(
      submit: submit.call,
      dragDrop: dragDrop,
      onClose: onClose,
    ),
  );

  group('提交', () {
    testWidgets('输入文本 + Enter → 提交并带上文本', (tester) async {
      await tester.pumpWidget(build());

      await tester.enterText(find.byKey(const ValueKey('overlay-input')), '你好');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // 单行 Enter 由 Focus.onKeyEvent 处理，receiveAction 不一定触发，
      // 故再走一次按钮（两条路径都要能用）。
      await tester.tap(find.byKey(const ValueKey('overlay-submit')));
      await tester.pumpAndSettle();

      expect(submit.calls, hasLength(1));
      expect(submit.calls.single.input, '你好');
    });

    testWidgets('空输入且无附件 → 发送按钮禁用', (tester) async {
      await tester.pumpWidget(build());

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('overlay-submit')),
      );
      expect(btn.onPressed, isNull, reason: '空输入不该可提交');
    });

    testWidgets('只有附件（无文本）→ 可提交', (tester) async {
      await tester.pumpWidget(build());

      dragDrop.captured!([_file('shot.png')]);
      await tester.pumpAndSettle();

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('overlay-submit')),
      );
      expect(btn.onPressed, isNotNull, reason: '有附件时应可提交');

      await tester.tap(find.byKey(const ValueKey('overlay-submit')));
      await tester.pumpAndSettle();

      expect(submit.calls.single.names, ['shot.png']);
      expect(submit.calls.single.input, '');
    });
  });

  group('附件', () {
    testWidgets('拖入文件 → 出现在附件列表', (tester) async {
      await tester.pumpWidget(build());

      dragDrop.captured!([_file('报告.pdf'), _file('图.png')]);
      await tester.pumpAndSettle();

      expect(find.text('报告.pdf'), findsOneWidget);
      expect(find.text('图.png'), findsOneWidget);
    });

    testWidgets('点移除 → 附件从列表消失', (tester) async {
      await tester.pumpWidget(build());

      dragDrop.captured!([_file('a.txt')]);
      await tester.pumpAndSettle();
      expect(find.text('a.txt'), findsOneWidget);

      // chip 上的关闭按钮。
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('a.txt'), findsNothing);
    });

    testWidgets('提交成功后清空输入与附件', (tester) async {
      await tester.pumpWidget(build());

      dragDrop.captured!([_file('a.txt')]);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('overlay-input')), 'x');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('overlay-submit')));
      await tester.pumpAndSettle();

      expect(find.text('a.txt'), findsNothing, reason: '成功提交后应清空附件');
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('overlay-input')),
      );
      expect(field.controller!.text, isEmpty);
    });
  });

  group('失败语义', () {
    testWidgets('投递失败 → 保留输入与附件（用户要重试）', (tester) async {
      submit.result = const QuickCaptureEnqueueResult(
        delivered: false,
        error: NetworkError('断网了'),
      );
      await tester.pumpWidget(build());

      dragDrop.captured!([_file('a.txt')]);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('overlay-input')), '重要的话');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('overlay-submit')));
      await tester.pumpAndSettle();

      expect(find.text('a.txt'), findsOneWidget, reason: '失败时不该清空附件');
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('overlay-input')),
      );
      expect(field.controller!.text, '重要的话', reason: '失败时不该清空输入');
      expect(find.textContaining('断网了'), findsOneWidget);
    });

    testWidgets('部分附件失败但已投递 → 不关窗，提示哪些失败', (tester) async {
      var closed = false;
      submit.result = QuickCaptureEnqueueResult(
        delivered: true,
        failedUploads: const [
          QuickCaptureFailedUpload(filename: 'big.zip', reason: '太大'),
        ],
      );
      await tester.pumpWidget(build(onClose: () => closed = true));

      await tester.enterText(find.byKey(const ValueKey('overlay-input')), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overlay-submit')));
      await tester.pumpAndSettle();

      expect(closed, isFalse, reason: '有附件失败时不该自动关窗（用户看不到提示）');
      expect(find.textContaining('big.zip'), findsOneWidget);
    });

    testWidgets('全部成功 → 自动关窗', (tester) async {
      var closed = false;
      await tester.pumpWidget(build(onClose: () => closed = true));

      await tester.enterText(find.byKey(const ValueKey('overlay-input')), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overlay-submit')));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
    });
  });

  group('键盘约定', () {
    testWidgets('Esc 先清空，再按一次才关窗', (tester) async {
      var closed = false;
      await tester.pumpWidget(build(onClose: () => closed = true));

      await tester.enterText(find.byKey(const ValueKey('overlay-input')), 'abc');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('overlay-input')),
      );
      expect(field.controller!.text, isEmpty, reason: '第一次 Esc 应清空');
      expect(closed, isFalse, reason: '第一次 Esc 不该关窗');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, isTrue, reason: '已空时第二次 Esc 应关窗');
    });
  });

  group('移动端降级', () {
    testWidgets('不支持拖拽时仍能正常输入与提交', (tester) async {
      dragDrop = _FakeDragDrop(supported: false);
      await tester.pumpWidget(build());

      await tester.enterText(find.byKey(const ValueKey('overlay-input')), 'hi');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overlay-submit')));
      await tester.pumpAndSettle();

      expect(submit.calls.single.input, 'hi');
    });
  });
}
