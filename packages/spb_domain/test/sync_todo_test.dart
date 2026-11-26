import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 待办容器里「工作区待处理」这一段的纯逻辑（对齐 webapp
/// `lib/workbench/workspace-sync-todo.ts`）。
///
/// ## 这个测试防的是什么
///
/// 三处错误都是**静默**的：
///
/// | 错误 | 后果 |
/// |---|---|
/// | refId 只取 review id | 同一路径的文件集合被 agent 改写（id 不变、revision 变）后，`stale` 判定错位 |
/// | 徽标把两类相加 | 显示 4 件「必须处理」，实际只有 3 件（同步事项不阻塞） |
/// | 归因查不到就编一个标题 | 用户以为这批文件是那一轮产出的，实际服务端根本没归因 |
void main() {
  WorkspaceSyncReview review(
    String id, {
    String path = 'reports',
    String revision = 'rev1',
    String turnId = '',
    bool directory = true,
    List<String> samples = const ['a.md'],
  }) => WorkspaceSyncReview(
    id: id,
    path: path,
    revision: revision,
    turnId: turnId,
    directory: directory,
    samples: samples,
  );

  group('syncTodoRefId', () {
    test('= id:revision（revision 变了就是另一条）', () {
      expect(syncTodoRefId(review('dir:g:reports')), 'dir:g:reports:rev1');
      expect(
        syncTodoRefId(review('dir:g:reports', revision: 'rev2')),
        'dir:g:reports:rev2',
      );
    });
  });

  group('buildWorkspaceSyncTodos', () {
    test('按路径排序，stale 排最后', () {
      final items = buildWorkspaceSyncTodos(
        [
          review('r3', path: 'z/'),
          review('r1', path: 'a/'),
          review('r2', path: 'm/'),
        ],
        staleRefIds: {'r2:rev1'},
      );

      expect(items.map((i) => i.review.id), ['r1', 'r3', 'r2']);
      expect(items.map((i) => i.state), [
        SyncTodoItemState.pending,
        SyncTodoItemState.pending,
        SyncTodoItemState.stale,
      ]);
    });

    test('stale 判据用 refId（同 id 不同 revision 不算 stale）', () {
      final items = buildWorkspaceSyncTodos(
        [review('r1', revision: 'rev2')],
        staleRefIds: {'r1:rev1'},
      );

      expect(items.single.state, SyncTodoItemState.pending);
    });

    test('空列表 → 空列表（不抛）', () {
      expect(buildWorkspaceSyncTodos(const []), isEmpty);
    });
  });

  group('todoBadgeLabel', () {
    test('两类分别计数：3 + 1 → 3+1（不是 4）', () {
      expect(todoBadgeLabel(3, 1), '3+1');
    });

    test('只有一类时显示该类的数', () {
      expect(todoBadgeLabel(3, 0), '3');
      expect(todoBadgeLabel(0, 2), '2');
    });

    test('都为 0 → null（不显示徽标）', () {
      expect(todoBadgeLabel(0, 0), isNull);
    });

    test('负数按 0 处理（防御脏数据）', () {
      expect(todoBadgeLabel(-1, 2), '2');
      expect(todoBadgeLabel(-1, -1), isNull);
    });
  });

  group('todoBadgeHint', () {
    test('两类都有 → 分别说明并点明阻塞性差异', () {
      final hint = todoBadgeHint(3, 1);

      expect(hint, contains('3 项待确认'));
      expect(hint, contains('1 项工作区待处理'));
      expect(hint, contains('不影响对话继续'), reason: '用户要知道那 1 项可以不理会');
    });

    test('只有确认卡 → 只解释阻塞那一类', () {
      expect(todoBadgeHint(3, 0), contains('不答复对话不会继续'));
      expect(todoBadgeHint(3, 0), isNot(contains('工作区待处理')));
    });

    test('只有同步事项 → 明说不影响对话', () {
      final hint = todoBadgeHint(0, 2);

      expect(hint, contains('2 项工作区待处理'));
      expect(hint, contains('不影响对话继续'));
    });

    test('没有徽标就没有解释（null，避免空 tooltip）', () {
      expect(todoBadgeHint(0, 0), isNull);
      expect(todoBadgeHint(-3, -1), isNull);
    });
  });

  group('describeSyncTodoAttribution', () {
    const labels = {'turn_abcdef123456': '整理本周周报'};

    test('查得到标题 → 用标题', () {
      final a = describeSyncTodoAttribution('turn_abcdef123456', labels);

      expect(a!.kind, SyncTodoAttributionKind.title);
      expect(a.text, '整理本周周报');
    });

    test('查不到 → 短 id（不编造标题）', () {
      final a = describeSyncTodoAttribution('turn_abcdef123456', const {});

      expect(a!.kind, SyncTodoAttributionKind.id);
      expect(a.text, 'turn_abc…', reason: '8 字符 + 省略号');
    });

    test('短 id 不截断', () {
      final a = describeSyncTodoAttribution('t1', const {});

      expect(a!.text, 't1');
    });

    test('没有 turn_id → null（不显示这一行）', () {
      expect(describeSyncTodoAttribution('', labels), isNull);
      expect(describeSyncTodoAttribution('   ', labels), isNull);
    });

    test('标题为空串时退化为短 id（服务端可能给空标题）', () {
      final a = describeSyncTodoAttribution('turn_abcdef123456', const {
        'turn_abcdef123456': '   ',
      });

      expect(a!.kind, SyncTodoAttributionKind.id);
    });
  });
}
