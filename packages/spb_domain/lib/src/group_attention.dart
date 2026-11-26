import 'package:spb_models/spb_models.dart';

/// 一次跨对话查询的待确认索引，不把查询窗口误当作全量计数。
class PendingConfirmationSummary {
  PendingConfirmationSummary.fromItems(
    List<ChatConfirmation> items, {
    required int limit,
    DateTime? now,
  }) : isTruncated = items.length >= limit {
    final at = now ?? DateTime.now();
    final seen = <String>{};
    final counts = <String, int>{};
    for (final item in items) {
      if (!item.isPending ||
          item.id.isEmpty ||
          item.groupId.isEmpty ||
          item.kind == 'attribution_feedback' ||
          (item.expiresAt != null && !item.expiresAt!.isAfter(at)) ||
          !seen.add(item.id)) {
        continue;
      }
      counts.update(item.groupId, (n) => n + 1, ifAbsent: () => 1);
    }
    byGroup = Map.unmodifiable(counts);
    total = counts.values.fold(0, (sum, n) => sum + n);
  }

  /// 服务端无 offset/cursor；满页只能证明这些条目存在，不能证明没有更多。
  final bool isTruncated;
  late final Map<String, int> byGroup;
  late final int total;
}

/// 列表已有目标快照的派生数据，不逐对话补查详情。
class GroupGoalSummary {
  GroupGoalSummary(GoalSnapshot snapshot) {
    progress = snapshot.progress;
    final currentId = snapshot.goal?.currentTaskId;
    var taskLabel = currentId;
    GoalTask? issueTask;
    var errors = 0;
    var blocked = 0;
    for (final task in snapshot.tasks) {
      // current_task_id 引用业务 taskId，不能与数据库行 id 比较。
      if (task.taskId == currentId && task.title.trim().isNotEmpty) {
        taskLabel = task.title.trim();
      }
      if (task.hasError) {
        errors++;
        issueTask ??= task;
      }
      if (task.isBlocked) blocked++;
    }
    for (final task in snapshot.tasks) {
      if (task.isBlocked) issueTask ??= task;
    }
    // progress 是服务端统计；任务明细缺失时仍能展示已知异常数量。
    errorCount = progress?.errorStopped ?? errors;
    blockedCount = progress?.blocked ?? blocked;
    currentTaskLabel = taskLabel;
    problemTask = issueTask;
  }

  late final GoalProgress? progress;
  late final String? currentTaskLabel;
  late final GoalTask? problemTask;
  late final int errorCount;
  late final int blockedCount;
  bool get needsAttention => errorCount > 0 || blockedCount > 0;
}
