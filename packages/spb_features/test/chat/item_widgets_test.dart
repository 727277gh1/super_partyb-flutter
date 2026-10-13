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
