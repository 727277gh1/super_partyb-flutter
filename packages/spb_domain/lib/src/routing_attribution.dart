import 'conversation_item.dart';

/// `routing_selected` 的「无聊」原因（复用当前/既有对话、无信息量）。
///
/// 值是**服务端写端**（Go `chatpipeline`）的 `GroupReason` / 兜底推导值，
/// 逐字对齐，勿凭猜测增删：
///
/// | 值 | 产出点 | 含义 |
/// |---|---|---|
/// | `fixed_reuse` | `pipeline_routing.go` 固定路由 | group 合法，原样复用（对话内发送，**最常见**） |
/// | `reuse_current` | 同上 | 复用当前 group |
/// | `user_specified_reuse` | 同上 | 用户显式指定 agent + 复用 |
/// | `classify_reuse` | `pipeline_classify.go` | 分类链判定复用 |
/// | `classify_fastpath` | 同上 | 分类链快路径命中 |
/// | `classify_confidence` | 同上 | 置信度过滤（未走 LLM） |
/// | `keep_current_group` | `pipeline_events.go` 兜底 | 旧路径兜底：维持当前 group |
/// | `reuse_group` | 同上 | 旧路径兜底：复用匹配到的 group |
const Set<String> _boringRoutingReasons = {
  'fixed_reuse',
  'reuse_current',
  'user_specified_reuse',
  'classify_reuse',
  'classify_fastpath',
  'classify_confidence',
  'keep_current_group',
  'reuse_group',
};

/// 该归属原因是否「无聊」（复用现有对话，对用户零信息量）。
///
/// null / 空串视为无聊：没有信息就不值得占一行。
bool isRoutineRoutingReason(String? reason) =>
    reason == null || reason.isEmpty || _boringRoutingReasons.contains(reason);

/// 「已新建对话」类原因：归属判定**创建**了一个新 group。
///
/// 同样取自服务端写端：`create_new` / `fixed_new`（请求带的 group id 已失效，
/// 被迫换新）/ `user_specified_new` / `classify_new_topic`，外加旧路径兜底
/// `create_new_group`。
const Set<String> _newGroupRoutingReasons = {
  'create_new',
  'fixed_new',
  'user_specified_new',
  'classify_new_topic',
  'create_new_group',
};

/// 归因徽标的呈现强度。
enum RoutingAttributionTone {
  /// 消息被送进了**另一个**对话——最值得被看见的情形。
  switched,

  /// 归属判定新建了一个对话（无归属入口 / 旧 group 失效 / 新话题）。
  newGroup,

  /// 有信息量但既非新建也非切换（未知原因原样透传）。
  info,
}

/// 用户气泡上的归属徽标（短标签 + 完整解释），或 null（不展示）。
///
/// 由 [routingAttributionNotice] 从 `routing_selected` 的原始字段派生；
/// [UserMessageItem] 只存原始值（`routingReason` / `routingSwitched`），
/// 中文映射集中在这一处，保持归约层不依赖文案。
final class RoutingAttributionNotice {
  const RoutingAttributionNotice({
    required this.label,
    required this.tone,
    this.tooltip,
  });

  /// 气泡上的短标签（中文，尽量 ≤ 6 字，移动端也要能认出来）。
  final String label;

  /// 呈现强度（决定图标 / 颜色）。
  final RoutingAttributionTone tone;

  /// 完整解释（Tooltip / 长按）。含原始 reason code 便于对日志；null = 无
  /// 额外解释可给。
  final String? tooltip;
}

/// 把 `routing_selected` 的原始字段解析成用户气泡上的徽标。
///
/// 判定顺序（**新建 > 切换**）：
///
/// 1. 原因是「新建对话」类 → 「已新建对话」；
/// 2. 原因无聊/未知但 `switched == true` → 「已切换对话」（注意 `classify_reuse`
///    也可能伴随切换：复用某条**相似**对话而不是当前这条——对用户同样是新信息）；
/// 3. 其余（无聊原因、无切换）→ null，不占任何空间。
///
/// 未知原因 fail-open：原样透传为徽标文案——「没见过的原因」更可能是服务端
/// 新增的有信息量分类，宁可多显示也不要静默吞掉。
RoutingAttributionNotice? routingAttributionNotice({
  String? reason,
  bool switched = false,
}) {
  final r = reason ?? '';
  if (_newGroupRoutingReasons.contains(r)) {
    return RoutingAttributionNotice(
      label: '已新建对话',
      tone: RoutingAttributionTone.newGroup,
      tooltip: _explain(reason: r, switched: switched),
    );
  }
  if (switched) {
    return RoutingAttributionNotice(
      label: '已切换对话',
      tone: RoutingAttributionTone.switched,
      tooltip: _explain(reason: r, switched: true),
    );
  }
  if (r.isEmpty || isRoutineRoutingReason(r)) return null;
  // 未知原因：原样透传，不编造中文解释。
  return RoutingAttributionNotice(
    label: r,
    tone: RoutingAttributionTone.info,
    tooltip: r,
  );
}

/// Tooltip 文案：把「发生了什么」讲成一句话，并附原始 code 便于对日志。
String? _explain({required String reason, required bool switched}) {
  final parts = <String>[];
  if (_newGroupRoutingReasons.contains(reason)) {
    parts.add('归属判定为这条消息新建了一个对话');
  } else if (switched) {
    parts.add('这条消息被送进了另一个对话');
  }
  if (reason.isNotEmpty) parts.add('原因：$reason');
  return parts.isEmpty ? null : parts.join('，');
}
