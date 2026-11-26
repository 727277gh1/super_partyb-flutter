import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 用户记忆页的交互契约。
///
/// 页面只收回调（HTTP 归装配层），故这里不需要 HTTP mock——验证的是
/// 「什么条件下展示什么、点了传什么、失败时留在哪里」。
void main() {
  Map<String, dynamic> row({
    required String id,
    String content = '偏好中文回复',
    String category = 'preference',
    String status = 'active',
    int learnedFromTurns = 2,
  }) => {
    'id': id,
    'userId': 'usr_1',
    'category': category,
    'content': content,
    'confidence': 0.8,
    'learnedFromTurns': learnedFromTurns,
    'status': status,
    'sourceGroupId': {'String': 'grp_1', 'Valid': true},
    'lastReinforcedAt': {'Time': '2026-11-20T10:00:00Z', 'Valid': true},
  };

  Future<void> pumpPage(
    WidgetTester tester, {
    required Future<List<UserMemory>> Function(
      UserMemoryStatus? status, {
      int limit,
      int offset,
    })
    loadMemories,
    UpdateMemory? updateMemory,
    ArchiveMemory? archiveMemory,
    void Function(String)? onOpenGroup,
    String? Function(String)? groupTitleOf,
    int pageSize = kMemoryPageSize,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SpbTheme.light(),
        home: MemoryPage(
          loadMemories: loadMemories,
          updateMemory: updateMemory,
          archiveMemory: archiveMemory,
          onOpenGroup: onOpenGroup,
          groupTitleOf: groupTitleOf,
          pageSize: pageSize,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认按「生效中」筛选，按分类分桶渲染', (tester) async {
    final asked = <UserMemoryStatus?>[];
    await pumpPage(
      tester,
      loadMemories: (status, {limit = kMemoryPageSize, offset = 0}) async {
        asked.add(status);
        return [
          UserMemory.fromJson(row(id: 'm1')),
          UserMemory.fromJson(row(id: 'm2', content: '住在杭州', category: 'fact')),
        ];
      },
    );

    expect(asked, [UserMemoryStatus.active], reason: '首屏对齐 webapp 的 active 默认');
    expect(find.text('偏好'), findsOneWidget);
    expect(find.text('事实'), findsOneWidget);
    expect(find.text('偏好中文回复'), findsOneWidget);
    expect(find.text('住在杭州'), findsOneWidget);
  });

  testWidgets('切到「已归档」重新拉取，且旧列表先清空（否则看不到筛选生效）', (tester) async {
    final asked = <UserMemoryStatus?>[];
    await pumpPage(
      tester,
      loadMemories: (status, {limit = kMemoryPageSize, offset = 0}) async {
        asked.add(status);
        return status == UserMemoryStatus.archived
            ? [
                UserMemory.fromJson(
                  row(id: 'm9', content: '旧的', status: 'archived'),
                ),
              ]
            : [UserMemory.fromJson(row(id: 'm1'))];
      },
    );

    await tester.tap(find.byKey(const ValueKey('memory-filter-archived')));
    await tester.pumpAndSettle();

    expect(asked, [UserMemoryStatus.active, UserMemoryStatus.archived]);
    expect(find.text('偏好中文回复'), findsNothing);
    expect(find.text('旧的'), findsOneWidget);
  });

  testWidgets('空态文案区分筛选（active 解释记忆从哪来）', (tester) async {
    await pumpPage(
      tester,
      loadMemories: (_, {limit = kMemoryPageSize, offset = 0}) async =>
          const [],
    );

    expect(find.textContaining('对话里学到的偏好与事实会自动出现在这里'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('memory-filter-archived')));
    await tester.pumpAndSettle();
    expect(find.text('没有已归档的记忆。'), findsOneWidget);
  });

  testWidgets('归档：调回调 + 从「生效中」列表移除 + 提示不再学习', (tester) async {
    final archived = <String>[];
    await pumpPage(
      tester,
      loadMemories: (_, {limit = kMemoryPageSize, offset = 0}) async => [
        UserMemory.fromJson(row(id: 'm1')),
        UserMemory.fromJson(row(id: 'm2', content: '第二条')),
      ],
      archiveMemory: (id) async => archived.add(id),
      updateMemory: (id, {content, category, status}) async =>
          UserMemory.fromJson(row(id: id, status: 'active')),
    );

    await tester.tap(find.byKey(const ValueKey('memory-archive-m1')));
    await tester.pumpAndSettle();

    expect(archived, ['m1']);
    expect(find.text('偏好中文回复'), findsNothing, reason: '当前筛选是 active');
    expect(find.text('第二条'), findsOneWidget);
    expect(find.textContaining('已归档'), findsWidgets);
  });

  testWidgets('恢复：把 status=active 交给 update 回调', (tester) async {
    final patched = <({String id, UserMemoryStatus? status})>[];
    await pumpPage(
      tester,
      loadMemories: (status, {limit = kMemoryPageSize, offset = 0}) async => [
        UserMemory.fromJson(row(id: 'm3', content: '归档了的', status: 'archived')),
      ],
      updateMemory: (id, {content, category, status}) async {
        patched.add((id: id, status: status));
        return UserMemory.fromJson(row(id: id));
      },
      archiveMemory: (_) async {},
    );

    await tester.tap(find.byKey(const ValueKey('memory-filter-archived')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('memory-restore-m3')));
    await tester.pumpAndSettle();

    expect(patched.single.id, 'm3');
    expect(patched.single.status, UserMemoryStatus.active);
    // 恢复到 active 后不再符合「已归档」筛选 → 从视图移除。
    expect(find.text('归档了的'), findsNothing);
  });

  testWidgets('编辑：对话框保存后回传内容/分类/状态，并回写列表', (tester) async {
    final patched = <({String id, String? content, Object? category})>[];
    await pumpPage(
      tester,
      loadMemories: (_, {limit = kMemoryPageSize, offset = 0}) async => [
        UserMemory.fromJson(row(id: 'm1')),
      ],
      updateMemory: (id, {content, category, status}) async {
        patched.add((id: id, content: content, category: category));
        return UserMemory.fromJson(
          row(id: id, content: content ?? '偏好中文回复', category: 'fact'),
        );
      },
      archiveMemory: (_) async {},
    );

    await tester.tap(find.byKey(const ValueKey('memory-edit-m1')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('memory-edit-content')),
      '用户住在杭州',
    );
    // 改分类：下拉项按 label 命中。
    await tester.tap(find.byKey(const ValueKey('memory-edit-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事实').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('memory-edit-save')));
    await tester.pumpAndSettle();

    expect(patched.single.id, 'm1');
    expect(patched.single.content, '用户住在杭州');
    expect(patched.single.category, UserMemoryCategory.fact);
    // 列表换成服务端返回的权威条目（分类桶也变了）。
    expect(find.text('用户住在杭州'), findsOneWidget);
  });

  testWidgets('编辑内容为空时保存按钮不提交（服务端把空串当「未传」）', (tester) async {
    var calls = 0;
    await pumpPage(
      tester,
      loadMemories: (_, {limit = kMemoryPageSize, offset = 0}) async => [
        UserMemory.fromJson(row(id: 'm1')),
      ],
      updateMemory: (id, {content, category, status}) async {
        calls++;
        return UserMemory.fromJson(row(id: id));
      },
    );

    await tester.tap(find.byKey(const ValueKey('memory-edit-m1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('memory-edit-content')),
      '   ',
    );
    await tester.tap(find.byKey(const ValueKey('memory-edit-save')));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.byKey(const ValueKey('memory-edit-dialog')), findsOneWidget);
  });

  testWidgets('加载失败展示错误态 + 重试真的重拉', (tester) async {
    var attempts = 0;
    await pumpPage(
      tester,
      loadMemories: (_, {limit = kMemoryPageSize, offset = 0}) async {
        attempts++;
        if (attempts == 1) throw const NetworkError('网络请求失败');
        return [UserMemory.fromJson(row(id: 'm1'))];
      },
    );

    expect(find.text('网络请求失败'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('memory-retry')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('偏好中文回复'), findsOneWidget);
  });

  testWidgets('未注入 update/archive 时不渲染写入口（只读列表）', (tester) async {
    await pumpPage(
      tester,
      loadMemories: (_, {limit = kMemoryPageSize, offset = 0}) async => [
        UserMemory.fromJson(row(id: 'm1')),
      ],
    );

    expect(find.byKey(const ValueKey('memory-edit-m1')), findsNothing);
    expect(find.byKey(const ValueKey('memory-archive-m1')), findsNothing);
  });

  testWidgets('来源对话：有标题时显示「来自…」，点击回调带上 groupId', (tester) async {
    final opened = <String>[];
    await pumpPage(
      tester,
      loadMemories: (_, {limit = kMemoryPageSize, offset = 0}) async => [
        UserMemory.fromJson(row(id: 'm1')),
      ],
      onOpenGroup: opened.add,
      groupTitleOf: (_) => '周报对话',
    );

    expect(find.textContaining('来自「周报对话」'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('memory-source-m1')));
    await tester.pumpAndSettle();
    expect(opened, ['grp_1']);
  });

  group('分页（issue #121）', () {
    testWidgets('满页时出「加载更多」，点按追加第二页；尾页不满后按钮收起', (tester) async {
      final calls = <({int limit, int offset})>[];
      await pumpPage(
        tester,
        pageSize: 2,
        loadMemories: (status, {limit = 0, offset = 0}) async {
          calls.add((limit: limit, offset: offset));
          return offset == 0
              ? [
                  UserMemory.fromJson(row(id: 'm1', content: '第一页甲')),
                  UserMemory.fromJson(row(id: 'm2', content: '第一页乙')),
                ]
              : [UserMemory.fromJson(row(id: 'm3', content: '第二页丙'))];
        },
      );

      expect(find.byKey(const ValueKey('memory-load-more')), findsOneWidget);
      expect(find.text('第二页丙'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('memory-load-more')));
      await tester.pumpAndSettle();

      expect(calls.map((c) => c.offset), [
        0,
        2,
      ], reason: '第二页从 offset = 首屏条数接续');
      expect(calls.every((c) => c.limit == 2), isTrue);
      expect(find.text('第二页丙'), findsOneWidget);
      // 尾页 1 条 < 2 → 判定没有下一页，按钮收起（`items.length == limit` 判据）。
      expect(find.byKey(const ValueKey('memory-load-more')), findsNothing);
    });

    testWidgets('首屏不足一页时不出「加载更多」', (tester) async {
      await pumpPage(
        tester,
        pageSize: 2,
        loadMemories: (_, {limit = 0, offset = 0}) async => [
          UserMemory.fromJson(row(id: 'm1')),
        ],
      );

      expect(find.byKey(const ValueKey('memory-load-more')), findsNothing);
    });

    testWidgets('切筛选后分页窗口归零，不把旧筛选的第二页追加进来', (tester) async {
      final calls = <({UserMemoryStatus? status, int offset})>[];
      await pumpPage(
        tester,
        pageSize: 2,
        loadMemories: (status, {limit = 0, offset = 0}) async {
          calls.add((status: status, offset: offset));
          final prefix = status?.wire ?? 'all';
          return [
            UserMemory.fromJson(
              row(id: '$prefix-$offset-a', content: '$prefix 第 $offset 页甲'),
            ),
            UserMemory.fromJson(
              row(
                id: '$prefix-$offset-b',
                content: '$prefix 第 $offset 页乙',
                status: status == UserMemoryStatus.archived
                    ? 'archived'
                    : 'active',
              ),
            ),
          ];
        },
      );

      // 先翻一页，让分页窗口走到 2。
      await tester.tap(find.byKey(const ValueKey('memory-load-more')));
      await tester.pumpAndSettle();
      expect(calls.last.offset, 2);

      await tester.tap(find.byKey(const ValueKey('memory-filter-archived')));
      await tester.pumpAndSettle();

      expect(calls.last.status, UserMemoryStatus.archived);
      expect(calls.last.offset, 0, reason: '新筛选从第一页开始');
    });

    testWidgets('归档让条目离开筛选时，下一页起点回退一格（避免漏项）', (tester) async {
      final offsets = <int>[];
      await pumpPage(
        tester,
        pageSize: 2,
        loadMemories: (status, {limit = 0, offset = 0}) async {
          offsets.add(offset);
          return offset == 0
              ? [
                  UserMemory.fromJson(row(id: 'm1')),
                  UserMemory.fromJson(row(id: 'm2', content: '第二条')),
                ]
              : [UserMemory.fromJson(row(id: 'm3', content: '第三条'))];
        },
        archiveMemory: (_) async {},
        updateMemory: (id, {content, category, status}) async =>
            UserMemory.fromJson(row(id: id)),
      );

      await tester.tap(find.byKey(const ValueKey('memory-archive-m1')));
      await tester.pumpAndSettle();
      expect(find.text('偏好中文回复'), findsNothing, reason: '当前筛选是 active');

      await tester.tap(find.byKey(const ValueKey('memory-load-more')));
      await tester.pumpAndSettle();

      // active 窗口整体上移一格 → 下一页起点从 2 回退到 1；重叠那条由 id 去重。
      expect(offsets, [0, 1]);
      expect(find.text('第二条'), findsOneWidget);
      expect(find.text('第三条'), findsOneWidget);
    });

    testWidgets('滚到距底阈值内自动取下一页（无需点按钮）', (tester) async {
      final offsets = <int>[];
      await pumpPage(
        tester,
        pageSize: 12,
        loadMemories: (status, {limit = 0, offset = 0}) async {
          offsets.add(offset);
          if (offset > 0) {
            return [UserMemory.fromJson(row(id: 'p2-1', content: '第二页第一条'))];
          }
          return [
            for (var i = 0; i < 12; i++)
              UserMemory.fromJson(row(id: 'p1-$i', content: '第一页第 $i 条')),
          ];
        },
      );

      await tester.drag(
        find.byKey(const ValueKey('memory-list')),
        const Offset(0, -4000),
      );
      await tester.pumpAndSettle();

      expect(offsets, [0, 12], reason: '滚到底部应自动发起下一页');
      expect(find.text('第二页第一条'), findsOneWidget);
    });
  });
}
