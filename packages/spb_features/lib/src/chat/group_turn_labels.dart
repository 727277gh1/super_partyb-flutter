import 'package:spb_domain/spb_domain.dart';

String? groupTurnLabel(
  GroupTurnSummary? summary, {
  required bool archived,
  required bool hasConfirmation,
}) {
  if (archived || hasConfirmation) return null;
  if (summary == null || !summary.isVerified) return '状态未核实';
  return switch (summary.activeStatus) {
    GroupTurnStatus.running => '执行中',
    GroupTurnStatus.queued => '排队中',
    GroupTurnStatus.pending => '待处理',
    _ => switch (summary.latestFinished?.status) {
      GroupTurnStatus.completed => '最近一轮已完成',
      GroupTurnStatus.failed => '最近一轮失败',
      GroupTurnStatus.cancelled => '最近一轮已取消',
      _ => '状态未核实',
    },
  };
}
