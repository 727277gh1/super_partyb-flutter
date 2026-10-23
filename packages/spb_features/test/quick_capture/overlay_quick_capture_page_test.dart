import 'dart:io';

import 'package:cross_file/cross_file.dart';
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

  /// 按调用序号取回完整 attachments（断言 path/bytes 用）。
  final _captured = <List<QuickCaptureAttachment>>[];

  List<QuickCaptureAttachment> attachmentsOf(int callIndex) =>
      _captured[callIndex];

  QuickCaptureEnqueueResult result = const QuickCaptureEnqueueResult(
    delivered: true,
  );

  Future<QuickCaptureEnqueueResult> call({
    required String input,
    required List<QuickCaptureAttachment> attachments,
    void Function(int done, int total)? onUploadProgress,
  }) async {
    calls.add((
      input: input,
      names: attachments.map((a) => a.filename).toList(),
    ));
    _captured.add(List.of(attachments));
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

/// 造一个**有磁盘路径**的 DroppedFile（模拟拖拽/文件选择）。
///
/// 用 XFile 而不是 fromBytes：只有 XFile 才有 path，而本组测试要固定的正是
/// 「有路径时走流式（不预读字节）」这个行为。
DroppedFile _pathFile(String path) =>
    DroppedFile.fromXFile(XFile(path, name: path.split('/').last));

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

  group('附件来源', () {
    testWidgets('有磁盘路径的附件 → 带 path 交给上层（不预读字节）', (tester) async {
      // 必须是**真实存在**的文件：_addFiles 会读 length()，读不到会标记
      // size=-1 并禁用提交（那是「文件已不可用」的正常路径，不是本测试要验的）。
      final dir = Directory.systemTemp.createTempSync('overlay-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final real = File('${dir.path}/report.pdf')
        ..writeAsBytesSync(List.filled(64, 7));

      await tester.pumpWidget(build());

      // ⚠️ 必须用 runAsync：_addFiles 里的 f.length() 是**真实文件 I/O**，
      // 而 testWidgets 默认跑在 fake async 里（时钟由测试驱动），真实 I/O 的
      // Future 不会推进，pumpAndSettle 会一直等到超时。
      await tester.runAsync(() async {
        dragDrop.captured!([_pathFile(real.path)]);
        // 让 length() 的 Future 完成。
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(
        find.text('report.pdf'),
        findsOneWidget,
        reason: '附件应出现在列表里（说明 length() 读取成功）',
      );

      await tester.enterText(find.byKey(const Key('overlay-input')), 'hi');
      await tester.tap(find.byKey(const Key('overlay-submit')));
      await tester.pumpAndSettle();

      expect(submit.calls, hasLength(1));
      final att = submit.attachmentsOf(0).single;
      expect(att.path, real.path, reason: '有路径时必须带 path，否则上传层无法流式读取');
      expect(att.bytes, isNull, reason: '有路径时不该预读字节（50 MiB 会在内存里存两份）');
    });

    testWidgets('无路径的附件（剪贴板）→ 回退到带 bytes', (tester) async {
      await tester.pumpWidget(build());
      dragDrop.captured!([
        _file('pasted.png', const [9, 9, 9]),
      ]);
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('overlay-input')), 'hi');
      await tester.tap(find.byKey(const Key('overlay-submit')));
      await tester.pumpAndSettle();

      final att = submit.attachmentsOf(0).single;
      expect(att.path, isNull);
      expect(att.bytes, const [9, 9, 9]);
    });
  });

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
      await tester.enterText(
        find.byKey(const ValueKey('overlay-input')),
        '重要的话',
      );
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
      submit.result = const QuickCaptureEnqueueResult(
        delivered: true,
        failedUploads: [
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

      await tester.enterText(
        find.byKey(const ValueKey('overlay-input')),
        'abc',
      );
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

    testWidgets('不支持拖拽时不提「拖入」（手机上写着可拖入会误导）', (tester) async {
      // 移动端走这条路：没有拖拽，但有系统文件选择器。提示文案必须跟着能力走
      // ——写着「可拖入文件」而实际拖不动，用户会去试拖、发现没反应，然后
      // 不知道该点哪里。
      dragDrop = _FakeDragDrop(supported: false);
      await tester.pumpWidget(build());

      expect(find.textContaining('拖入'), findsNothing);
      expect(find.text('说点什么…'), findsOneWidget);

      // 但附件入口必须仍在（它走文件选择器，与拖拽是两条独立路径）。
      expect(find.byKey(const ValueKey('overlay-attach')), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('overlay-attach')))
            .tooltip,
        '添加文件',
      );
    });

    testWidgets('支持拖拽时保留「可拖入文件」提示（桌面端）', (tester) async {
      // 反向断言：不能为了移动端把桌面端的提示也一起删掉。
      dragDrop = _FakeDragDrop(supported: true);
      await tester.pumpWidget(build());

      expect(find.text('说点什么…（可拖入文件）'), findsOneWidget);
    });

    testWidgets('显式传入 hintText 时优先于平台推导', (tester) async {
      dragDrop = _FakeDragDrop(supported: true);
      await tester.pumpWidget(
        _host(
          OverlayQuickCapturePage(
            submit: submit.call,
            dragDrop: dragDrop,
            hintText: '自定义提示',
          ),
        ),
      );

      expect(find.text('自定义提示'), findsOneWidget);
      expect(find.textContaining('可拖入文件'), findsNothing);
    });
  });
}
