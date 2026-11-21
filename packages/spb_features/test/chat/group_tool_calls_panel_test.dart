import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// [GroupToolCallsPanel] 的 widget 测试。
void main() {
  ToolCallItem call(
    String id, {
    String name = 'read_file',
    Map<String, dynamic>? args,
    String? output = 'ok',
    bool isComplete = true,
    String turnId = 'turn_1',
  }) => ToolCallItem(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1),
    name: name,
    turnId: turnId,
    args: args,
    output: output,
    isComplete: isComplete,
  );

  Future<void> pumpPanel(
    WidgetTester tester, {
    required List<ToolCallItem> toolCalls,
    bool showHeader = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupToolCallsPanel(
            toolCalls: toolCalls,
            showHeader: showHeader,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('空态', () {
    testWidgets('无工具调用时显示空提示', (tester) async {
      await pumpPanel(tester, toolCalls: const []);

      expect(find.byKey(const ValueKey('toolcalls-empty')), findsOneWidget);
      expect(find.text('这一轮还没有工具调用'), findsOneWidget);
      expect(find.byKey(const ValueKey('toolcalls-list')), findsNothing);
    });

    testWidgets('可自定义空提示', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GroupToolCallsPanel(toolCalls: [], emptyHint: '暂无工具活动'),
          ),
        ),
      );
      expect(find.text('暂无工具活动'), findsOneWidget);
    });
  });

  group('渲染', () {
    testWidgets('显示头部与计数', (tester) async {
      await pumpPanel(tester, toolCalls: [call('t1'), call('t2')]);

      expect(find.text('工具调用'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('showHeader=false 时不渲染标题行', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [call('t1', name: 'bash')],
        showHeader: false,
      );

      expect(find.text('工具调用'), findsNothing);
      // 瓦片仍然渲染。
      expect(find.text('bash'), findsOneWidget);
    });

    testWidgets('工具名出现在瓦片上', (tester) async {
      await pumpPanel(tester, toolCalls: [call('t1', name: 'write_file')]);

      expect(find.text('write_file'), findsOneWidget);
    });

    testWidgets('最新调用排在最上（倒序）', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [
          call('old', name: 'first_tool'),
          call('new', name: 'second_tool'),
        ],
      );

      final newY = tester.getTopLeft(find.text('second_tool')).dy;
      final oldY = tester.getTopLeft(find.text('first_tool')).dy;
      expect(newY, lessThan(oldY));
    });
  });

  group('状态', () {
    testWidgets('未完成（output null）显示执行中', (tester) async {
      // 运行中有无限动画的 CircularProgressIndicator，不能用 pumpAndSettle。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupToolCallsPanel(
              toolCalls: [call('t1', isComplete: false, output: null)],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('执行中'), findsOneWidget);
    });

    testWidgets('完成且输出正常显示完成', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [call('t1', output: '文件内容', isComplete: true)],
      );

      expect(find.text('完成'), findsOneWidget);
    });

    testWidgets('完成且输出像错误时显示失败', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [
          call('t1', output: 'Error: file not found', isComplete: true),
        ],
      );

      expect(find.text('失败'), findsOneWidget);
    });
  });

  group('详情展开', () {
    testWidgets('展开后显示参数与结果', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [
          call(
            't1',
            name: 'read_file',
            args: {'path': '/tmp/a.txt'},
            output: 'hello',
            isComplete: true,
          ),
        ],
      );

      // 默认折叠。
      expect(find.text('参数'), findsNothing);

      await tester.tap(find.text('read_file'));
      await tester.pumpAndSettle();

      expect(find.text('参数'), findsOneWidget);
      expect(find.textContaining('/tmp/a.txt'), findsOneWidget);
      expect(find.text('结果'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('无参数时展开不显示参数块', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [call('t1', name: 'noop', output: 'done', isComplete: true)],
      );

      await tester.tap(find.text('noop'));
      await tester.pumpAndSettle();

      expect(find.text('参数'), findsNothing);
      expect(find.text('结果'), findsOneWidget);
    });
  });

  group('边界', () {
    testWidgets('多个工具独立展开（互不影响）', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [
          call('t1', name: 'tool_a', output: 'OUT_A', isComplete: true),
          call('t2', name: 'tool_b', output: 'OUT_B', isComplete: true),
        ],
      );

      // 展开 tool_a。
      await tester.tap(find.text('tool_a'));
      await tester.pumpAndSettle();

      expect(find.text('OUT_A'), findsOneWidget);
      expect(find.text('OUT_B'), findsNothing);
    });

    testWidgets('超长输出限高不撑爆（内部滚动）', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [
          call(
            't1',
            name: 'big',
            output: List.generate(200, (i) => 'line $i').join('\n'),
            isComplete: true,
          ),
        ],
      );

      await tester.tap(find.text('big'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 限高 240 以内。
      final box = tester.getSize(
        find.ancestor(
          of: find.textContaining('line 0'),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(box.height, lessThanOrEqualTo(240));
    });
  });
}
