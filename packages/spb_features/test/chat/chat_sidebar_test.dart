import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';

/// [ChatSidebar] 的 widget 测试。
void main() {
  ChatSidebarTab tab(
    String label, {
    IconData icon = Icons.folder,
    int badge = 0,
    String body = '',
  }) => ChatSidebarTab(
    label: label,
    icon: icon,
    badge: badge,
    content: Center(child: Text(body.isEmpty ? '$label-content' : body)),
  );

  Future<void> pumpSidebar(
    WidgetTester tester, {
    required List<ChatSidebarTab> tabs,
    int initialIndex = 0,
    VoidCallback? onClose,
    bool showHeader = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: Container()),
              SizedBox(
                width: 320,
                child: ChatSidebar(
                  tabs: tabs,
                  initialIndex: initialIndex,
                  onClose: onClose,
                  showHeader: showHeader,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('渲染', () {
    testWidgets('渲染全部 tab 标签', (tester) async {
      await pumpSidebar(tester, tabs: [tab('文件'), tab('待办'), tab('诊断')]);

      expect(find.text('文件'), findsOneWidget);
      expect(find.text('待办'), findsOneWidget);
      expect(find.text('诊断'), findsOneWidget);
    });

    testWidgets('默认显示第一个 tab 的内容', (tester) async {
      await pumpSidebar(
        tester,
        tabs: [
          tab('文件', body: 'FILE_BODY'),
          tab('待办', body: 'TODO_BODY'),
        ],
      );

      // IndexedStack 保持所有子项挂载，但只有当前 index 可见。
      expect(find.text('FILE_BODY'), findsOneWidget);
      // 第二个虽挂载但被 IndexedStack 隐藏（offstage）。
      expect(find.text('TODO_BODY'), findsNothing);
    });

    testWidgets('initialIndex 指定初始 tab', (tester) async {
      await pumpSidebar(
        tester,
        tabs: [
          tab('文件', body: 'FILE_BODY'),
          tab('待办', body: 'TODO_BODY'),
        ],
        initialIndex: 1,
      );

      expect(find.text('TODO_BODY'), findsOneWidget);
      expect(find.text('FILE_BODY'), findsNothing);
    });

    testWidgets('空 tabs 显示占位不白屏', (tester) async {
      await pumpSidebar(tester, tabs: const []);

      expect(find.text('侧边栏无内容'), findsOneWidget);
    });

    testWidgets('showHeader=false 时不渲染头部', (tester) async {
      await pumpSidebar(tester, tabs: [tab('文件')], showHeader: false);

      expect(find.text('侧边栏'), findsNothing);
      // tab 栏仍在。
      expect(find.text('文件'), findsOneWidget);
    });

    testWidgets('提供 onClose 时渲染关闭按钮', (tester) async {
      await pumpSidebar(tester, tabs: [tab('文件')], onClose: () {});

      expect(find.byKey(const ValueKey('sidebar-close')), findsOneWidget);
    });

    testWidgets('未提供 onClose 时不渲染关闭按钮', (tester) async {
      await pumpSidebar(tester, tabs: [tab('文件')]);

      expect(find.byKey(const ValueKey('sidebar-close')), findsNothing);
    });
  });

  group('tab 切换', () {
    testWidgets('点击 tab 切换内容', (tester) async {
      await pumpSidebar(
        tester,
        tabs: [
          tab('文件', body: 'FILE_BODY'),
          tab('待办', body: 'TODO_BODY'),
        ],
      );

      expect(find.text('FILE_BODY'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sidebar-tab-待办')));
      await tester.pumpAndSettle();

      expect(find.text('TODO_BODY'), findsOneWidget);
      expect(find.text('FILE_BODY'), findsNothing);
    });

    testWidgets('切回原 tab 时内容仍存在（IndexedStack 保持挂载）', (tester) async {
      await pumpSidebar(
        tester,
        tabs: [
          tab('文件', body: 'FILE_BODY'),
          tab('待办', body: 'TODO_BODY'),
        ],
      );

      await tester.tap(find.byKey(const ValueKey('sidebar-tab-待办')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-tab-文件')));
      await tester.pumpAndSettle();

      expect(find.text('FILE_BODY'), findsOneWidget);
    });

    testWidgets('切换 tab 保留各 tab 内部 State（展开状态不丢）', (tester) async {
      // 用一个带内部状态的 widget 作为 tab 内容，验证 IndexedStack 的
      // 「保持挂载」语义——这正是选它而非 TabBarView 的理由。
      await pumpSidebar(
        tester,
        tabs: [
          ChatSidebarTab(
            label: '文件',
            icon: Icons.folder,
            content: const _StatefulProbe(),
          ),
          tab('待办', body: 'TODO_BODY'),
        ],
      );

      // 初始：probe 内部计数为 0。
      expect(find.text('count=0'), findsOneWidget);

      // 点一下让计数变成 1。
      await tester.tap(find.text('count=0'));
      await tester.pumpAndSettle();
      expect(find.text('count=1'), findsOneWidget);

      // 切走再切回。
      await tester.tap(find.byKey(const ValueKey('sidebar-tab-待办')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-tab-文件')));
      await tester.pumpAndSettle();

      // State 保留（若用 TabBarView 的懒加载，这里会回到 count=0）。
      expect(find.text('count=1'), findsOneWidget);
    });
  });

  group('徽标', () {
    testWidgets('badge > 0 时显示计数', (tester) async {
      await pumpSidebar(tester, tabs: [tab('文件'), tab('待办', badge: 3)]);

      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('badge == 0 时不显示徽标', (tester) async {
      await pumpSidebar(tester, tabs: [tab('文件'), tab('待办', badge: 0)]);

      // 标签本身在，但没有数字徽标。
      expect(find.text('待办'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('badge 变化时更新', (tester) async {
      await pumpSidebar(tester, tabs: [tab('待办', badge: 1)]);
      expect(find.text('1'), findsOneWidget);

      await pumpSidebar(tester, tabs: [tab('待办', badge: 5)]);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('1'), findsNothing);
    });
  });

  group('边界', () {
    testWidgets('initialIndex 越界时被钳制到合法范围', (tester) async {
      await pumpSidebar(
        tester,
        tabs: [
          tab('文件', body: 'FILE_BODY'),
          tab('待办', body: 'TODO_BODY'),
        ],
        initialIndex: 99,
      );

      // 应落在最后一个 tab。
      expect(find.text('TODO_BODY'), findsOneWidget);
    });

    testWidgets('tabs 缩短后 index 保持合法（不崩溃）', (tester) async {
      await pumpSidebar(
        tester,
        tabs: [
          tab('A', body: 'A_BODY'),
          tab('B', body: 'B_BODY'),
        ],
        initialIndex: 1,
      );
      expect(find.text('B_BODY'), findsOneWidget);

      // 缩到只剩一个 tab。
      await pumpSidebar(
        tester,
        tabs: [tab('A', body: 'A_BODY')],
        initialIndex: 1,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('A_BODY'), findsOneWidget);
    });
  });
}

/// 带内部计数 State 的探针 widget（验证 IndexedStack 保持挂载）。
class _StatefulProbe extends StatefulWidget {
  const _StatefulProbe();

  @override
  State<_StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<_StatefulProbe> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(
        onPressed: () => setState(() => _count++),
        child: Text('count=$_count'),
      ),
    );
  }
}
