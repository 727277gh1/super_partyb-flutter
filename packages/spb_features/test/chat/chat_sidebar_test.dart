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
          const ChatSidebarTab(
            label: '文件',
            icon: Icons.folder,
            content: _StatefulProbe(),
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

  group('惰性加载（issue #16：未激活的 tab 不构建）', () {
    /// 每个 tab 用一个记录挂载次数的探针作 content。
    ///
    /// 用**挂载计数**而不是「内容文本是否出现」：`IndexedStack` 会把子项设成
    /// offstage，`find.text` 对未激活的占位本来就找不到——那样断言不出「是没
    /// 构建还是只是隐藏」。计数器直接证明 `initState` 有没有跑。
    Future<Map<String, int>> pumpCounting(
      WidgetTester tester, {
      int initialIndex = 0,
    }) async {
      final counts = <String, int>{'A': 0, 'B': 0, 'C': 0};
      await pumpSidebar(
        tester,
        initialIndex: initialIndex,
        tabs: [
          for (final key in ['A', 'B', 'C'])
            ChatSidebarTab(
              label: key,
              icon: Icons.folder,
              content: _MountProbe(
                onMount: () => counts[key] = counts[key]! + 1,
              ),
            ),
        ],
      );
      return counts;
    }

    testWidgets('初始只构建第一个 tab（B/C 不发请求）', (tester) async {
      final counts = await pumpCounting(tester);

      expect(counts, {'A': 1, 'B': 0, 'C': 0});
    });

    testWidgets('切到第二个 tab 才构建它（且只构建一次）', (tester) async {
      final counts = await pumpCounting(tester);
      expect(counts['B'], 0);

      await tester.tap(find.byKey(const ValueKey('sidebar-tab-B')));
      await tester.pumpAndSettle();

      expect(counts, {'A': 1, 'B': 1, 'C': 0});
    });

    testWidgets('切回已激活的 tab 不重新构建（状态保留）', (tester) async {
      final counts = await pumpCounting(tester);

      await tester.tap(find.byKey(const ValueKey('sidebar-tab-B')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-tab-A')));
      await tester.pumpAndSettle();

      // 回到 A 不重建（A 仍挂载），B 也不被卸载。
      expect(counts, {'A': 1, 'B': 1, 'C': 0});
    });

    testWidgets('第三个 tab 始终未被切到 → 永不构建', (tester) async {
      final counts = await pumpCounting(tester);

      await tester.tap(find.byKey(const ValueKey('sidebar-tab-B')));
      await tester.pumpAndSettle();

      expect(counts['C'], 0, reason: '没看过 C，不该为它付构建与取数成本');
    });

    testWidgets('initialIndex 指向的 tab 视为已激活（不渲染空占位）', (tester) async {
      // 注：`initialIndex` 会被 `clamp(0, (len-1).clamp(0, 1))` 限制在 0..1
      // （**既有行为**，见 `_ChatSidebarState.initState`——不是本 issue 引入的）。
      // 这里断言的是：无论钳制到哪个下标，那个 tab 必须是已激活的（不能是
      // 空占位）。故用 initialIndex=1 避开钳制干扰。
      final counts = await pumpCounting(tester, initialIndex: 1);

      expect(counts, {'A': 0, 'B': 1, 'C': 0});
    });

    testWidgets('initialIndex 越界被钳制后，钳到的那个 tab 仍是已激活的', (tester) async {
      // 防的是：钳制把 `_index` 换成一个未访问过的值 → 首屏渲染成空占位。
      final counts = await pumpCounting(tester, initialIndex: 99);

      // 钳到 1（见上一条注释），该 tab 已构建。
      expect(counts, {'A': 0, 'B': 1, 'C': 0});
      expect(tester.takeException(), isNull);
    });

    testWidgets('惰性化后仍保留已激活 tab 的内部 State（不退回懒销毁）', (tester) async {
      // 惰性加载**不能**把「切回来状态不丢」这个 IndexedStack 的原有语义弄丢。
      await pumpSidebar(
        tester,
        tabs: [
          const ChatSidebarTab(
            label: '文件',
            icon: Icons.folder,
            content: _StatefulProbe(),
          ),
          tab('待办', body: 'TODO_BODY'),
        ],
      );

      await tester.tap(find.text('count=0'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-tab-待办')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-tab-文件')));
      await tester.pumpAndSettle();

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

/// 记录「自己被挂载了」的探针（惰性加载断言用，issue #16）。
///
/// 只看 `initState`：它跑一次就说明面板被真实构建了，即它的取数请求会发出。
class _MountProbe extends StatefulWidget {
  const _MountProbe({required this.onMount});

  final VoidCallback onMount;

  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
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
