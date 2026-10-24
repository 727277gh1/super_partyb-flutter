import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_ui/spb_ui.dart';

/// 构造一个「提交成功」的 [FlushResult]。
///
/// 成功分支必有 `turn_id`——[FlushResult.committed] 以它非空为判据，
/// 故测试里的「成功」不能省略它，否则会被当成异常响应。
FlushResult _okFlush() => FlushResult.fromJson({
  'turn_id': 'turn_1',
  'flush_strategy': 'latest_only',
});

/// 包一层 MaterialApp（组件依赖 Theme 与 Directionality）。
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 捕获剪贴板写入内容的盒子。
///
/// ## 为什么不用 `Clipboard.getData` 回读
///
/// `Clipboard` 走 `SystemChannels.platform` 平台通道，测试环境没有真实剪贴板
/// 后端——回读只会拿到 null，于是「写入是否发生」根本无法断言。改为拦截通道
/// 调用本身，直接看 `Clipboard.setData` 收到的参数。
class _ClipboardCapture {
  String? text;
}

/// 装一个假的平台通道，捕获后续的 `Clipboard.setData`。
///
/// 用例结束自动复位（`addTearDown`），避免影响其它用例。
_ClipboardCapture _captureClipboard(WidgetTester tester) {
  final capture = _ClipboardCapture();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      capture.text = (call.arguments as Map)['text'] as String?;
    }
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return capture;
}

/// 收集子树里所有文本节点的纯文本，拼接后返回。
///
/// 用于断言 Markdown 是否被真正解析：渲染后的纯文本不应残留 `**` / 反引号
/// 等语法标记。不能直接用 `find.text`——加粗/行内代码等内联结构会被合并进
/// 同一个富文本段落，不存在独立的 `Text` widget 承载「重点」二字。
String _renderedPlainText(WidgetTester tester) {
  final buf = StringBuffer();
  for (final el in tester.allElements) {
    final w = el.widget;
    if (w is RichText) {
      buf.write(w.text.toPlainText());
    }
  }
  return buf.toString();
}

void main() {
  group('MessageComposer 键盘行为', () {
    testWidgets('Enter 发送（回调收到文本且输入框被清空）', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '你好');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, ['你好']);
      // 清空很重要：否则用户会以为没发出去而重复发送。
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('Shift+Enter 换行，不发送', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '第一行');
      await tester.pump();

      // 按住 Shift 再按 Enter。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(submitted, isEmpty, reason: 'Shift+Enter 不应触发发送');
    });

    testWidgets('空输入按 Enter 不发送', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, isEmpty);
    });

    testWidgets('纯空白输入按 Enter 不发送（trim 后为空）', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '   \n  ');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, isEmpty);
    });

    testWidgets('提交的文本被 trim', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '  你好  ');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, ['你好']);
    });

    testWidgets('Esc 清空输入且不发送', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '要丢弃的内容');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(submitted, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('发送按钮：空输入时禁用，有文本时可用', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(_host(MessageComposer(onSubmit: submitted.add)));

      // 空输入 → 禁用。
      final sendButton = find.byKey(const ValueKey('composer-send'));
      expect(
        tester.widget<IconButton>(sendButton).onPressed,
        isNull,
        reason: '空输入时发送按钮应禁用',
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      expect(tester.widget<IconButton>(sendButton).onPressed, isNotNull);

      await tester.tap(sendButton);
      await tester.pump();
      expect(submitted, ['x']);
    });

    testWidgets('onSubmit 为 null 时输入框禁用', (tester) async {
      await tester.pumpWidget(_host(const MessageComposer(onSubmit: null)));

      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    });
  });

  group('MessageComposer 「立即发送」（flush）', () {
    testWidgets('点「立即发送」触发注入回调一次', (tester) async {
      var flushed = 0;
      await tester.pumpWidget(
        _host(
          MessageComposer(
            onSubmit: null,
            onFlush: () async {
              flushed++;
              return _okFlush();
            },
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('composer-flush')));
      await tester.pumpAndSettle();

      expect(flushed, 1);
    });

    testWidgets('输入框为空时「立即发送」仍可用（它推的是已排队的消息）', (tester) async {
      var flushed = 0;
      await tester.pumpWidget(
        _host(
          MessageComposer(
            onSubmit: null,
            onFlush: () async {
              flushed++;
              return _okFlush();
            },
          ),
        ),
      );

      // 关键区别：与「发送」不同，本入口不以输入框内容为条件。
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('composer-flush')),
      );
      expect(button.onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('composer-flush')));
      await tester.pumpAndSettle();
      expect(flushed, 1);
    });

    testWidgets('在途时禁用按钮（防重复点）', (tester) async {
      final gate = Completer<void>();
      var flushed = 0;
      await tester.pumpWidget(
        _host(
          MessageComposer(
            onSubmit: null,
            onFlush: () async {
              flushed++;
              await gate.future;
              return _okFlush();
            },
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('composer-flush')));
      await tester.pump();

      // 在途：按钮禁用（连点不应发多次请求）。
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('composer-flush')))
            .onPressed,
        isNull,
      );
      expect(flushed, 1);

      gate.complete();
      await tester.pumpAndSettle();
      // 完成后恢复可用。
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('composer-flush')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('回调抛错时给用户提示并复位（不产生未处理异常）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageComposer(
              onSubmit: null,
              onFlush: () async => throw const NetworkError('连不上'),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('composer-flush')));
      await tester.pumpAndSettle();

      // 错误必须被本组件消化：`onPressed` 会丢弃 Future，上抛就变成
      // **未处理异步异常**，上层无从捕获。
      expect(tester.takeException(), isNull);
      expect(find.textContaining('立即发送失败'), findsOneWidget);
      // 且按钮已复位（不会永久禁用）。
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('composer-flush')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('非 SpbError 异常也不会变成未处理异常', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageComposer(
              onSubmit: null,
              onFlush: () async => throw StateError('boom'),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('composer-flush')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('composer-flush')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('待确认时弹策略选择，选中后按该策略重试（修复前是死锁）', (tester) async {
      final strategies = <String>[];
      await tester.pumpWidget(
        _host(
          MessageComposer(
            onSubmit: null,
            onFlush: () async => FlushResult.fromJson({
              'status': 'confirmation_required',
              'options': ['latest_only', 'merge_all', 'new_group'],
            }),
            onFlushWithStrategy: (strategy) async {
              strategies.add(strategy);
              return _okFlush();
            },
          ),
        ),
      );

      // ⚠️ 这里**不能**用 `pumpAndSettle`：待确认时本组件仍在「在途」状态
      // （按钮位置是无限旋转的 `CircularProgressIndicator`），而流程在
      // `await showDialog(...)` 上等用户决策，动画不会停，`pumpAndSettle`
      // 会一直等到超时。固定时长推进既确定又覆盖对话框入场动画。
      await tester.tap(find.byKey(const ValueKey('composer-flush')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 服务端 HTTP 200 + confirmation_required = 什么都没提交，必须弹窗。
      expect(find.text('有多条待处理消息'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('flush-strategy-new_group')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(strategies, ['new_group'], reason: '不把用户选的策略传下去，用户就永远走不到提交成功');
    });

    testWidgets('待确认但未接线选策略回调 → 报错而非静默（不能假装成功）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageComposer(
              onSubmit: null,
              onFlush: () async => FlushResult.fromJson({
                'status': 'confirmation_required',
                'options': ['merge_all'],
              }),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('composer-flush')));
      await tester.pumpAndSettle();

      expect(find.textContaining('立即发送失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 按钮复位，用户可以重试。
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('composer-flush')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('未接线时不显示「立即发送」入口', (tester) async {
      await tester.pumpWidget(_host(const MessageComposer(onSubmit: null)));

      expect(find.byKey(const ValueKey('composer-flush')), findsNothing);
      // 「发送」按钮不受影响。
      expect(find.byKey(const ValueKey('composer-send')), findsOneWidget);
    });

    testWidgets('「立即发送」不清空输入框（与「发送」语义不同）', (tester) async {
      // 必须给一个非 null 的 onSubmit：否则输入框本身是 disabled 的，
      // 无法用 enterText 写入草稿。
      await tester.pumpWidget(
        _host(
          MessageComposer(onSubmit: (_) {}, onFlush: () async => _okFlush()),
        ),
      );

      await tester.enterText(find.byType(TextField), '还没写完的草稿');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('composer-flush')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '还没写完的草稿',
        reason: 'flush 推的是已排队的消息，不应动草稿',
      );
    });
  });

  /// ## 这个 group 防的是什么（issue #31）
  ///
  /// 输入区在窄屏溢出过：那句快捷键说明实测宽 **287.5dp**，且它在 `Row` 里
  /// 不是 `Expanded`/`Flexible`——于是把整行撑破（320dp 溢出 104px、360dp
  /// 64px、390dp 34px）。修复是按 `SpbBreakpoints.compact`（720dp）在窄屏
  /// **隐藏**它。
  ///
  /// ⚠️ 既有用例都在**默认 800dp 窗口**（宽屏档）下跑，故「窄屏不溢出」这条
  /// 不变式在它们里**永远不会被触发**——这正是缺陷被掩盖的原因。故这里显式
  /// 把窗口压到真机宽度。
  ///
  /// 用例只断言「不溢出」与「该显示时才显示」，不锁定具体布局——布局会随
  /// 设计调整，而这两条是不变式。
  group('MessageComposer 窄屏（issue #31）', () {
    for (final width in [320.0, 360.0, 390.0, 412.0]) {
      testWidgets('宽 $width dp 下输入区无 RenderFlex 溢出', (tester) async {
        tester.view.physicalSize = Size(width, 200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          _host(
            MessageComposer(
              onSubmit: _noop,
              // 「立即发送」**必须接线**：未接线时溢出量小 52px，
              // 缺陷会被掩盖（issue #31 实测）。
              onFlush: () async => _okFlush(),
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: '窄屏输入区溢出会盖住发送按钮，用户点不到（issue #31）',
        );
        // 两个按钮都还在（溢出时右侧那个会被裁掉）。
        expect(find.byKey(const ValueKey('composer-flush')), findsOneWidget);
        expect(find.byKey(const ValueKey('composer-send')), findsOneWidget);
      });
    }

    testWidgets('窄屏隐藏快捷键说明，宽屏保留', (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      Future<void> pumpAt(double width) async {
        tester.view.physicalSize = Size(width, 200);
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(
          _host(
            MessageComposer(onSubmit: _noop, onFlush: () async => _okFlush()),
          ),
        );
        await tester.pump();
      }

      const hint = 'Enter 发送 · Shift+Enter 换行';

      await pumpAt(390);
      expect(
        find.text(hint),
        findsNothing,
        reason: '窄屏没有余量摆它；截断成「Shift+En…」比不显示更困惑（issue #31）',
      );

      // 阈值取 `SpbBreakpoints.compact`（720dp）的边界值：719 隐藏、720 显示。
      await pumpAt(719);
      expect(find.text(hint), findsNothing);

      await pumpAt(720);
      expect(
        find.text(hint),
        findsOneWidget,
        reason: '桌面端有物理键盘，这行说明只在宽屏有意义（issue #31）',
      );

      await pumpAt(1000);
      expect(find.text(hint), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '宽屏摆出提示文本后仍不应溢出（反向守卫）');
    });
  });

  group('UserMessageBubble', () {
    testWidgets('渲染文本且右对齐', (tester) async {
      await tester.pumpWidget(_host(const UserMessageBubble(text: '用户说的话')));

      expect(find.text('用户说的话'), findsOneWidget);
      final align = tester.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.centerRight);
    });

    testWidgets('复制按钮把完整原文写入剪贴板', (tester) async {
      // ⚠️ 复制的是**组件入参的原文**，不是渲染后的富文本。用一段带换行的
      // 文本，能同时发现「只复制了首行」这类截断错误。
      const original = '第一行\n第二行 with **markdown**';
      final copied = _captureClipboard(tester);

      await tester.pumpWidget(_host(const UserMessageBubble(text: original)));
      await tester.tap(find.byType(CopyIconButton));
      await tester.pump();

      expect(copied.text, original, reason: '必须复制完整原文（含换行与语法字符）');

      // 「已复制」反馈靠一个延迟定时器复位。不推进时间的话，测试结束时它仍是
      // pending，flutter_test 直接报「A Timer is still pending...」。
      await tester.pump(SpbDuration.copyFeedback);
    });
  });

  group('AssistantMessageBubble', () {
    testWidgets('渲染 Markdown 文本', (tester) async {
      // 非流式：reveal 关闭，文档整段渲染。
      await tester.pumpWidget(
        _host(const AssistantMessageBubble(text: '助手的回复')),
      );
      await tester.pumpAndSettle();

      expect(find.text('助手的回复'), findsOneWidget);
    });

    testWidgets('渲染 Markdown 语法（加粗不再出现字面 **）', (tester) async {
      await tester.pumpWidget(
        _host(const AssistantMessageBubble(text: '**重点** 与 `code`')),
      );
      await tester.pumpAndSettle();

      // 取所有可渲染文本节点的纯文本，拼起来检查。
      final rendered = _renderedPlainText(tester);
      // Markdown 语法不应原样残留：无 `**`、无反引号。
      expect(rendered, isNot(contains('**')));
      expect(rendered, isNot(contains('`')));
      // 内容本身仍可见。
      expect(rendered, contains('重点'));
      expect(rendered, contains('code'));
    });

    testWidgets('流式且文本为空时显示「正在生成」占位', (tester) async {
      // 空文本 + 流式中：必须给占位，否则是 0 高度气泡（用户以为卡住）。
      await tester.pumpWidget(
        _host(const AssistantMessageBubble(text: '', isStreaming: true)),
      );

      expect(find.text('正在生成…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // 让动画控制器停下，避免 pending timer 警告。
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('流式中不提供复制入口（文本仍在变，会复制到半截）', (tester) async {
      await tester.pumpWidget(
        _host(const AssistantMessageBubble(text: '半句话', isStreaming: true)),
      );
      await tester.pump();

      expect(
        find.byType(CopyIconButton),
        findsNothing,
        reason: '流式中复制会拿到半截内容，此时必须没有入口',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('完成后提供复制入口，且复制完整原文', (tester) async {
      const original = '第一段\n\n第二段 with `code`';
      final copied = _captureClipboard(tester);

      await tester.pumpWidget(
        _host(const AssistantMessageBubble(text: original)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CopyIconButton), findsOneWidget);
      await tester.tap(find.byType(CopyIconButton));
      await tester.pump();

      expect(copied.text, original, reason: '必须复制完整原文而非渲染后的富文本');

      // 同上：把「已复制」的复位定时器跑完，避免 pending timer。
      await tester.pump(SpbDuration.copyFeedback);
    });

    testWidgets('流式透传 isStreaming 给渲染器，完成后用 SelectionArea 包裹', (tester) async {
      await tester.pumpWidget(
        _host(const AssistantMessageBubble(text: '半句话', isStreaming: true)),
      );
      await tester.pump();

      // 流式：Markdown 渲染器收到 isStreaming=true，且不包 SelectionArea
      //（尾部每帧重建，选择不稳定——见气泡类文档）。
      final streaming = tester.widget<GptMarkdown>(find.byType(GptMarkdown));
      expect(streaming.isStreaming, isTrue);
      expect(find.byType(SelectionArea), findsNothing);

      // 完成后：isStreaming=false，且整段被 SelectionArea 包裹（可选择）。
      await tester.pumpWidget(_host(const AssistantMessageBubble(text: '半句话')));
      await tester.pumpAndSettle();

      final settled = tester.widget<GptMarkdown>(find.byType(GptMarkdown));
      expect(settled.isStreaming, isFalse);
      expect(find.byType(SelectionArea), findsOneWidget);

      // 收尾，避免 pending timer/ticker 警告。
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('ThoughtTile（可折叠）', () {
    testWidgets('默认折叠，展开后显示全文', (tester) async {
      await tester.pumpWidget(_host(const ThoughtTile(text: '第一行思考\n第二行思考')));

      expect(find.text('思考过程'), findsOneWidget);
      // 默认折叠：全文不可见。
      expect(find.text('第一行思考\n第二行思考'), findsNothing);

      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();

      expect(find.text('第一行思考\n第二行思考'), findsOneWidget);
    });

    testWidgets('流式中标题为「思考中…」', (tester) async {
      await tester.pumpWidget(
        _host(const ThoughtTile(text: '思考内容', isStreaming: true)),
      );

      expect(find.text('思考中…'), findsOneWidget);
    });

    testWidgets('长首行摘要被截断', (tester) async {
      final long = '很长的第一行' * 20;
      await tester.pumpWidget(_host(ThoughtTile(text: long)));

      // 摘要截断到 60 字符 + 省略号，故完整长串不应出现在摘要里。
      expect(find.text(long), findsNothing);
    });
  });

  group('ToolCallTile', () {
    testWidgets('执行中显示「执行中」且带进度指示', (tester) async {
      await tester.pumpWidget(
        _host(const ToolCallTile(name: 'bash', output: null)),
      );

      expect(find.text('bash'), findsOneWidget);
      expect(find.text('执行中'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('完成显示「完成」；展开后可见参数与结果', (tester) async {
      await tester.pumpWidget(
        _host(
          const ToolCallTile(
            name: 'read',
            args: {'path': '/tmp/a.txt'},
            output: 'file contents',
            isComplete: true,
          ),
        ),
      );

      expect(find.text('完成'), findsOneWidget);
      // 折叠态看不到参数与结果。
      expect(find.text('参数'), findsNothing);

      await tester.tap(find.text('read'));
      await tester.pumpAndSettle();

      expect(find.text('参数'), findsOneWidget);
      expect(find.text('结果'), findsOneWidget);
      // 参数以缩进 JSON 呈现。
      expect(find.textContaining('/tmp/a.txt'), findsOneWidget);
      expect(find.text('file contents'), findsOneWidget);
    });

    testWidgets('输出含 error 特征时显示「失败」', (tester) async {
      await tester.pumpWidget(
        _host(
          const ToolCallTile(
            name: 'bash',
            output: 'Error: command not found',
            isComplete: true,
          ),
        ),
      );

      expect(find.text('失败'), findsOneWidget);
    });

    // ── 折叠态不构造子内容（守卫，防性能回退）────────────────────────
    //
    // ## 为什么这条值得单独守
    //
    // 工具调用是时间线上**数量最多**的行（一轮对话几十上百条），而参数与
    // 结果可能极长（构建日志、文件内容）。它们之所以不是性能问题，全靠
    // `ExpansionTile` 的一个内部行为：
    //
    //   `flutter/lib/src/widgets/expansible.dart`
    //     `shouldRemoveBody = closed && !widget.maintainState`
    //     `child: shouldRemoveBody ? null : result`
    //
    // 即折叠时 `children` **完全不构造**（连 `JsonEncoder.convert` 与
    // `SelectableText` 都不会跑）。而 `ExpansionTile.maintainState` 默认
    // false，本组件也没有传——这个默认值是唯一的屏障。
    //
    // ## 会怎么被破坏（都不是明显的错）
    //
    // 1. 有人为了「展开时也别闪一下」给 `ExpansionTile` 传 `maintainState: true`
    //    ——折叠态的每条工具卡就常驻一棵子树，几百条历史时每帧都要布局；
    // 2. 有人为了「早点拿到 JSON 字符串」把 `JsonEncoder...convert(args)` 提到
    //    `build()` 顶部算好再传给 children——那样即使 children 不构造，转换
    //    也已经跑过（大输出上实测 4.7 µs/次，乘上条数不再可忽略）；
    // 3. 有人把 `children` 改成 `ListView` / `Column` 放在 ExpansionTile 外面
    //    自己控制可见性——`Visibility(maintainState: true)` 之类同样常驻。
    //
    // 三条都不会让任何功能测试变红，只会让滚动慢慢变卡。
    //
    // ## ⚠️ 必须用 `skipOffstage: false`，否则这条守卫是假绿
    //
    // 第一版写的是 `find.byType(SelectableText)`（默认 `skipOffstage: true`），
    // 把 `maintainState: true` 传进 `ExpansionTile` 后**仍然通过**——实测确认。
    //
    // 原因：`ExpansionTile.maintainState = true` 时子内容**照样会被构造**，只是
    // 被包进 `Offstage`（`expansible.dart` 的 `result = Offstage(...)`，仅
    // `shouldRemoveBody` 为真时才换成 `null`）。而 `find.*` 的默认
    // `skipOffstage: true` 会把 `Offstage` 子树整个过滤掉——于是「构造了但被
    // 隐藏」与「根本没构造」在断言层面**完全同形**。
    //
    // 这与本仓库反复出现的那类「绿不代表对」同型：断言的是「看不见」而不是
    // 「没构造」，而性能成本恰恰由后者决定（`Offstage` 仍会 layout 子树）。
    // 故这里一律带 `skipOffstage: false`。
    testWidgets('折叠态不构造参数与结果（性能守卫）', (tester) async {
      await tester.pumpWidget(
        _host(
          ToolCallTile(
            name: 'bash',
            args: const {'cmd': 'ls'},
            output: 'x' * 1000,
            isComplete: true,
          ),
        ),
      );

      // 折叠态：两个小节标题都不存在（含 offstage 子树里也不存在）。
      expect(find.text('参数', skipOffstage: false), findsNothing);
      expect(find.text('结果', skipOffstage: false), findsNothing);
      // 核心断言：`SelectableText` 一个都没被**构造**。
      //
      // 只看「屏幕上看不见」是不够的：`maintainState: true` 会把它们构造出来
      // 再藏进 `Offstage`，视觉一样，但每帧都要布局。
      expect(find.byType(SelectableText, skipOffstage: false), findsNothing);
      // 但标题本身必须在（否则上面几条在「组件根本没渲染」时也会通过）。
      expect(find.text('bash'), findsOneWidget);

      // ⚠️ 反向验证：给 `ToolCallTile` 的 `ExpansionTile` 加上
      // `maintainState: true`，本条用例应失败（`SelectableText` 变成 2 个）。
      // 实测确认过——第一版不带 `skipOffstage: false` 时它**不会**失败。
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('展开后才构造参数与结果', (tester) async {
      await tester.pumpWidget(
        _host(
          ToolCallTile(
            name: 'bash',
            args: const {'cmd': 'ls'},
            output: 'x' * 1000,
            isComplete: true,
          ),
        ),
      );

      expect(find.byType(SelectableText, skipOffstage: false), findsNothing);

      await tester.tap(find.text('bash'));
      await tester.pumpAndSettle();

      // 参数 + 结果各一个 `SelectableText`。
      expect(find.text('参数'), findsOneWidget);
      expect(find.text('结果'), findsOneWidget);
      expect(find.byType(SelectableText), findsNWidgets(2));
      // 参数以缩进 JSON 呈现（`{\n  "cmd": "ls"\n}`）。
      expect(find.textContaining('"cmd": "ls"'), findsOneWidget);
      expect(find.text('x' * 1000), findsOneWidget);

      // 再折回去：子内容重新消失（证明不是「展开过就一直常驻」）。
      await tester.tap(find.text('bash'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText, skipOffstage: false), findsNothing);
    });

    // ── 「输出像不像错误」的判据（性能 + 语义）──────────────────────
    //
    // `_looksLikeError` 曾在**每次 build** 都跑一次 `output.toLowerCase()`
    // ——那是一次全量拷贝（Dart `String` 不可变），实测 1 MB 输出 6.93 ms。
    // 现在改成零分配的大小写不敏感比较，且结果在 State 里缓存。
    //
    // 下面两条分别钉住「语义没变」与「不再每次重算」。

    testWidgets('错误特征判据：大小写不敏感、位置敏感（与旧实现语义一致）', (tester) async {
      // 前缀类（error / exception）只看**开头**；子串类（traceback /
      // failed）任意位置。这张表与旧 `toLowerCase()` 实现逐条对齐过。
      const cases = <String, bool>{
        'Error: command not found': true, // 大写开头
        'ERROR at line 3': true, // 全大写
        'error': true, // 恰好等于前缀
        'exception thrown': true,
        'Exception: boom': true,
        'a\nTraceback (most recent call last)': true, // 子串 + 换行
        'build FAILED': true, // 子串 + 大写
        'xxfailedxx': true, // 子串在中间
        'ok, no problem': false,
        'fail': false, // 差一个字符
        'tracebac': false, // 少一个字符
        '  error: leading space': false, // 前缀含空格 → 不算开头
        '中文输出失败': false, // 无 ASCII 特征
      };

      for (final entry in cases.entries) {
        await tester.pumpWidget(
          _host(
            ToolCallTile(name: 'bash', output: entry.key, isComplete: true),
          ),
        );
        expect(
          find.text('失败'),
          entry.value ? findsOneWidget : findsNothing,
          reason:
              '输出 ${entry.key.replaceAll('\n', r'\n')} 期望 hasFailed=${entry.value}',
        );
      }
    });

    testWidgets('输出未变时不重算错误判据（State 缓存）', (tester) async {
      // 用同一个 String **实例**反复重建：缓存命中应完全不重算。
      //
      // ⚠️ 断言方式：`_looksLikeError` 是私有静态方法，无法直接计数。
      // 故用「大输出 + 多次重建」的耗时作**间接**证据？不行——毫秒断言在
      // 本仓库是禁止的（随机器与 debug/release 漂移）。
      //
      // 改用行为证据：缓存失效的**唯一**入口是 `output`/`isComplete` 变化，
      // 故只要能证明「同一实例的重建不改变图标状态，而换实例会改变」，
      // 就说明判据确实挂在缓存上（而不是每次现算——现算也能得到同样结果，
      // 所以这条单独不足以证明缓存）。
      //
      // 真正的性能守卫在 `perf_probe` 侧：见 `conversation_page_perf_test.dart`
      // 的「一次 build 至多扫一遍」。这里只钉「语义在重建后仍正确」，
      // 防止有人把缓存写成「只在 initState 算一次」而漏掉 `didUpdateWidget`。
      final long = 'x' * 50000;
      await tester.pumpWidget(
        _host(ToolCallTile(name: 'bash', output: long, isComplete: true)),
      );
      expect(find.text('完成'), findsOneWidget);

      // 同一个实例重建：仍是「完成」。
      await tester.pumpWidget(
        _host(ToolCallTile(name: 'bash', output: long, isComplete: true)),
      );
      expect(find.text('完成'), findsOneWidget);

      // 换成带错误特征的新实例：必须变成「失败」。
      await tester.pumpWidget(
        _host(
          ToolCallTile(name: 'bash', output: 'Error: $long', isComplete: true),
        ),
      );
      expect(find.text('失败'), findsOneWidget);

      // `isComplete` 翻转也要生效：`hasFailed` 是
      // `isComplete && _looksLikeError(output)`，故 `isComplete` 从 true
      // 变 false 时必须重新算（否则会一直显示「失败」）。
      //
      // ⚠️ 这里不能断言「执行中」：`isRunning` 的判据是 `output == null`，
      // 而本条的 output 非空，故 isComplete=false 走的是「完成」分支——
      // 那是既有行为，与本节的缓存无关。
      //
      // ⚠️ **必须复用同一个 output 实例**，否则 `identical(oldWidget.output,
      // widget.output)` 已为 false，`output` 判据自己就会触发重算——那样即便
      // `isComplete` 没进判据，用例也照样通过（实测确认过：去掉该判据后
      // 本条仍绿，是个假绿）。
      const errorOutput = 'Error: boom';
      await tester.pumpWidget(
        _host(
          const ToolCallTile(
            name: 'bash',
            output: errorOutput,
            isComplete: true,
          ),
        ),
      );
      expect(find.text('失败'), findsOneWidget);

      await tester.pumpWidget(
        _host(
          const ToolCallTile(
            name: 'bash',
            output: errorOutput,
            isComplete: false,
          ),
        ),
      );
      expect(find.text('失败'), findsNothing);
      expect(find.text('完成'), findsOneWidget);
    });
  });

  group('ConfirmationCard', () {
    testWidgets('渲染问题与选项按钮', (tester) async {
      await tester.pumpWidget(
        _host(
          const ConfirmationCard(
            question: '是否继续执行？',
            options: ['继续', '取消'],
            onResolve: _noop,
          ),
        ),
      );

      expect(find.text('需要你的确认'), findsOneWidget);
      expect(find.text('是否继续执行？'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('点击选项回调携带该选项文案', (tester) async {
      final resolved = <String>[];
      await tester.pumpWidget(
        _host(
          ConfirmationCard(
            question: '选一个',
            options: const ['A', 'B'],
            onResolve: resolved.add,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('confirmation-option-B')));
      await tester.pump();

      expect(resolved, ['B']);
    });

    testWidgets('options 为空时退化为默认「继续 / 取消」', (tester) async {
      // 服务端 confirmation_required 的 payload 可能只给 recommendation，
      // 不给 options（见 BuildConfirmationRequiredPayload）。此时必须给兜底按钮，
      // 否则卡片是一个无法操作的死块。
      await tester.pumpWidget(
        _host(
          const ConfirmationCard(
            question: '无选项',
            options: [],
            onResolve: _noop,
          ),
        ),
      );

      expect(find.text('继续'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('resolved 时按钮禁用且标题变为「已确认」', (tester) async {
      final resolved = <String>[];
      await tester.pumpWidget(
        _host(
          ConfirmationCard(
            question: '已处理',
            options: const ['继续'],
            resolved: true,
            onResolve: resolved.add,
          ),
        ),
      );

      expect(find.text('已确认'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirmation-option-继续')),
      );
      expect(button.onPressed, isNull);
      expect(resolved, isEmpty);
    });

    testWidgets('busy 时禁用按钮并显示「提交中」', (tester) async {
      await tester.pumpWidget(
        _host(
          const ConfirmationCard(
            question: '提交中',
            options: ['继续'],
            busy: true,
            onResolve: _noop,
          ),
        ),
      );

      expect(find.text('提交中…'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirmation-option-继续')),
      );
      expect(button.onPressed, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('onResolve 为 null 时按钮禁用（只读展示）', (tester) async {
      await tester.pumpWidget(
        _host(const ConfirmationCard(question: '只读', options: ['继续'])),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirmation-option-继续')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('FollowUpChips', () {
    testWidgets('渲染建议 chip 且点击回调携带文本', (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(
        _host(
          FollowUpChips(suggestions: const ['继续深入', '换个方案'], onTap: tapped.add),
        ),
      );

      expect(find.text('继续深入'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('follow-up-换个方案')));
      await tester.pump();

      expect(tapped, ['换个方案']);
    });

    testWidgets('空建议列表渲染为空白（不占高度）', (tester) async {
      await tester.pumpWidget(_host(const FollowUpChips(suggestions: [])));

      expect(find.byType(ActionChip), findsNothing);
    });

    testWidgets('onTap 为 null 时 chip 不可点', (tester) async {
      await tester.pumpWidget(
        _host(const FollowUpChips(suggestions: ['只读建议'])),
      );

      final chip = tester.widget<ActionChip>(
        find.byKey(const ValueKey('follow-up-只读建议')),
      );
      expect(chip.onPressed, isNull);
    });
  });
}

void _noop(String _) {}
