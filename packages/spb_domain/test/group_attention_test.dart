import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 10);
  ChatConfirmation confirmation(
    String id,
    String group, {
    String status = 'pending',
    String kind = 'continue_suggestion',
    DateTime? expiresAt,
  }) => ChatConfirmation(
    id: id,
    turnId: 'turn',
    groupId: group,
    userId: 'user',
    kind: kind,
    status: status,
    createdAt: now,
    expiresAt: expiresAt,
  );

  test('按归属去重，排除已处理、过期和旁路反馈', () {
    final summary = PendingConfirmationSummary.fromItems(
      [
        confirmation('a', 'g1'),
        confirmation('a', 'g1'),
        confirmation('b', 'g2'),
        confirmation('c', 'g1'),
        confirmation('d', 'g1', status: 'resolved'),
        confirmation('e', 'g1', expiresAt: now),
        confirmation('f', 'g1', kind: 'attribution_feedback'),
        confirmation('', 'g1'),
        confirmation('x', ''),
      ],
      limit: 50,
      now: now,
    );
    expect(summary.byGroup, {'g1': 2, 'g2': 1});
    expect(summary.total, 3);
    expect(summary.isTruncated, isFalse);
    expect(() => summary.byGroup['g1'] = 9, throwsUnsupportedError);
  });

  test('完整性按原始窗口判定，不能因过滤去重就声称已取全', () {
    final summary = PendingConfirmationSummary.fromItems(
      [confirmation('a', 'g1'), confirmation('a', 'g1')],
      limit: 2,
      now: now,
    );
    expect(summary.total, 1);
    expect(summary.isTruncated, isTrue);
    expect(summary.byGroup['g2'], isNull);
  });

  GroupGoalSummary goal({
    List<Map<String, dynamic>> tasks = const [],
    Map<String, dynamic>? progress,
  }) => GroupGoalSummary(
    GoalSnapshot.fromJson({
      'goal': {'current_task_id': 'TASK-005'},
      'tasks': tasks,
      if (progress != null) 'progress': progress,
    }),
  );

  test('当前任务匹配业务 taskId，不匹配数据库行 id；缺标题回退编号', () {
    expect(
      goal(
        tasks: [
          {'id': 'TASK-005', 'task_id': 'TASK-001', 'title': '不能误选'},
          {'id': 'row5', 'task_id': 'TASK-005', 'title': ' 发布客户端 '},
        ],
      ).currentTaskLabel,
      '发布客户端',
    );
    expect(goal().currentTaskLabel, 'TASK-005');
    expect(
      goal(
        tasks: [
          {'task_id': 'TASK-005', 'title': '  '},
        ],
      ).currentTaskLabel,
      'TASK-005',
    );
  });

  test('失败优先于阻塞；恢复后的历史原因不再被选中', () {
    final summary = goal(
      tasks: [
        {'task_id': 'TASK-001', 'status': 'blocked', 'error_reason': '等待依赖'},
        {'task_id': 'TASK-002', 'status': 'completed', 'error_reason': '旧错误'},
        {
          'task_id': 'TASK-003',
          'status': 'error_stopped',
          'error_reason': '检查失败',
        },
      ],
    );
    expect(summary.errorCount, 1);
    expect(summary.blockedCount, 1);
    expect(summary.problemTask?.errorReason, '检查失败');
    expect(summary.needsAttention, isTrue);
    final restored = goal(
      tasks: [
        {'task_id': 'TASK-003', 'status': 'in_progress', 'error_reason': '旧错误'},
      ],
    );
    expect(restored.needsAttention, isFalse);
    expect(restored.problemTask, isNull);
  });

  test('任务明细缺失仍保留服务端进度里的异常数量', () {
    final summary = goal(
      progress: {'total': 5, 'blocked': 2, 'error_stopped': 1},
    );
    expect(summary.errorCount, 1);
    expect(summary.blockedCount, 2);
    expect(summary.problemTask, isNull);
  });
}
