import 'package:spb_models/spb_models.dart';

/// 待办清单变更的 `op`（服务端 `todo.changed` 的 payload 必填键）。
///
/// 值域来自 Go `workers/groupsync/control.go`：新挂起项出现（`created`）、
/// 用户拍板完成（`resolved`）与文件删除等引起的自动清理（`removed`）。
///
/// 保持 enum 而非 String 的**唯一**目的：让消费方认识的值有名字；
/// [unknown] 的存在保证服务端将来新增 op 时**不会**被静默丢弃——那会让
/// 「拍板后清单没刷新」这种症状重新出现。
enum TodoChangeOp {
  /// 新挂起项出现（`putHoldLocked` 新建 hold 时发）。
  created('created'),

  /// 某条挂起项已被处理（`ResolveReview` 成功路径发）。
  resolved('resolved'),

  /// 挂起项因文件删除等原因自动消失，消费方仍需重拉列表。
  removed('removed'),

  /// 服务端新增了本客户端还不认识的 op。
  ///
  /// 消费方对它的正确反应与其它 op **相同**：重拉一次。它只说明「变了」，
  /// 不说明怎么变——这正是失效通知的语义。
  unknown('');

  const TodoChangeOp(this.wire);

  /// 服务端原值。
  final String wire;

  /// 解析服务端 `op`；未知或缺失退化为 [unknown]。
  static TodoChangeOp fromWire(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    for (final op in values) {
      if (op != unknown && op.wire == value) return op;
    }
    return unknown;
  }
}

/// 一条「待办清单过期了」的失效通知（由 `todo.changed` 归一化而来）。
///
/// ## 它是**通知**，不是数据通道
///
/// 真源永远是 GET：`workspace-sync/reviews`（拍板项，服务端 `Holds`）与
/// `workspace-sync/local-files` 的 `sync_state`（知情项）。事件只回答
/// 「你手上的清单是否过期」，消费方收到后**重拉一次**即可：
///
/// - **不得**从 [reviewId] / [path] / [reason] 推导列表或计数——载荷会缺键，
///   且与重拉后的真实状态可能不一致（服务端注释原话：payload 会丢，
///   会与后续状态不一致）；
/// - 事件本身**会丢**（`Transient`，不落库、不回放），丢了只是回落到轮询
///   （本仓设置页的 `WorkspaceSyncReviewsSection` 是 15 秒）。故订阅方必须是
///   幂等的「重拉一次」，不能承担任何状态推导。
///
/// ## 信封是群级，没有 turn
///
/// 同步拦截发生在 groupsync 的扫描/文件事件里，多数与 turn 无关；而
/// `chat_events.turn_id` 是 NOT NULL，故服务端只广播不落库。这也是客户端
/// **必须把它挡在游标推进之外**的原因（见 [ChatStreamController.todoChanges]）。
///
/// ## 为什么本类住在 domain 而不是 models
///
/// 与 [GoalUpdate] / [GroupUpdate] 同层：它是**事件归一化后的通道载荷**，
/// 不是 REST DTO。`spb_models` 只镜像服务端契约常量与 DTO，事件→载荷的
/// 归一（含容错与默认值）属于 domain。
class TodoChange {
  const TodoChange({
    required this.op,
    required this.groupId,
    this.reviewId,
    this.path,
    this.directory = false,
    this.reason,
    this.turnId,
    this.at,
  });

  /// 变更类型（服务端只保证这个键）。
  final TodoChangeOp op;

  /// 变更所在 group。
  ///
  /// 优先取事件信封的 `groupId`（它是 broker 的 fan-out 路由键，服务端不填
  /// 就等于白发，故正常情况下一定有），缺失时才回退 payload 的 `group_id`。
  ///
  /// **可能为空串**（异常载荷）。消费方不得因此丢弃通知——「不知道哪个组
  /// 变了」时保守重拉一次（多一次 GET 好过漏一次，与 webapp
  /// `todoChangedMatches` 同一判据）。用 [matchesGroup] 做这条判定，
  /// 不要在两端各写一份。
  final String groupId;

  /// 挂起项 id（服务端 `SyncReview.ID`）。
  ///
  /// 仅供日志与「哪一条变了」的调试定位。`created` 时它指向**新**挂起项，
  /// `resolved` 时指向**刚被删掉**的那条——**不能**拿它去 GET（`resolved` 的
  /// id 已经查不到了，服务端 `Reviews()` 的 map key 已无此项）。
  final String? reviewId;

  /// 挂起项相对 workspace 的路径（目录级挂起时指向目录）。
  final String? path;

  /// 是否为目录级挂起（服务端只在 true 时带这个键）。
  final bool directory;

  /// 挂起原因（服务端 `reason`，值域见 [WorkspaceSyncReviewReason]）。
  ///
  /// 已归一成 enum：未知原因退化为 [WorkspaceSyncReviewReason.unknown] 而
  /// **不是** null——服务端新增原因时不得让这条通知变成「没信息」。
  final WorkspaceSyncReviewReason? reason;

  /// 扫描时的 turn 归因（服务端只在能**确定**归属时才填）。
  ///
  /// 缺失是常态：并发多轮、后台对账、用户手动上传等场景服务端一律留空
  /// （宁可没归因也不猜）。消费方**不得**编造标题。
  final String? turnId;

  /// 事件到达时间。
  final DateTime? at;

  /// 该通知是否可能影响 [groupId] 这个对话的待办清单。
  ///
  /// 判据（与 webapp `todoChangedMatches` 一致，避免两端漂移）：
  /// - 本通知的 groupId 为空 → **true**（不确定范围，保守刷新）；
  /// - 否则精确匹配。
  ///
  /// ## 为什么「不确定」偏向刷新
  ///
  /// 事件是 Transient，缺键是服务端明确允许的形态。漏刷新的表现是「另一端
  /// 停在待办页，新卡迟迟不出现」——那正是本事件要消灭的症状；多刷新一次只是
  /// 一次 GET。
  bool matchesGroup(String groupId) {
    final target = this.groupId.trim();
    if (target.isEmpty) return true;
    return target == groupId.trim();
  }

  /// 该通知是否可能影响 [groupIds] 这批对话里的**任何一个**。
  ///
  /// 供「跨 group 聚合」的消费方用（设置页的待确认同步项区块查的是同步范围，
  /// 不是单个对话）：判据与 [matchesGroup] 一致——本通知 groupId 缺失时返回
  /// **true**（不确定范围，保守刷新），否则精确匹配集合里的一项（两侧都 trim）。
  ///
  /// 集合为空时返回 false：没有查询过任何对话，重拉也不可能多出内容。
  bool matchesAnyGroup(Iterable<String> groupIds) {
    final target = groupId.trim();
    if (target.isEmpty) return true;
    for (final id in groupIds) {
      if (id.trim() == target) return true;
    }
    return false;
  }

  /// 从事件构造；非 `todo.changed` 返回 null。
  ///
  /// 只有 `eventType` 是硬条件：payload 缺 `op`、缺其它任何键、`op` 未知，
  /// 都**照样**返回一条通知（[TodoChangeOp.unknown]）。丢掉一条「变了」
  /// 通知等于让用户多等一轮轮询，而这条事件的全部价值就是省掉那段等待。
  static TodoChange? fromEvent(ChatEvent ev) {
    if (ev.eventType != EventTypes.todoChanged) return null;
    final payload = ev.payload ?? const <String, dynamic>{};
    final envelopeGroupId = ev.groupId.trim();
    final payloadGroupId = _string(payload['group_id']) ?? '';
    return TodoChange(
      op: TodoChangeOp.fromWire(payload['op']),
      groupId: envelopeGroupId.isNotEmpty ? envelopeGroupId : payloadGroupId,
      reviewId: _string(payload['review_id']),
      path: _string(payload['path']),
      // 服务端只在 true 时带这个键（`json:",omitempty"` 语义），故缺失 = false。
      directory: payload['directory'] == true,
      reason: _reason(payload['reason']),
      turnId: _string(payload['turn_id']),
      at: ev.createdAt,
    );
  }

  @override
  String toString() =>
      'TodoChange($op, group=$groupId'
      '${reviewId != null ? ', review=$reviewId' : ''}'
      '${path != null ? ', path=$path' : ''}'
      '${directory ? ', dir' : ''}'
      '${reason != null ? ', reason=${reason!.wire}' : ''})';
}

/// 取 payload 里的字符串；非字符串 / 空串 / null 一律 null。
///
/// 不抛异常：畸形载荷只该让某个字段缺失，不该让整条通知消失。
String? _string(Object? raw) {
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : raw;
  }
  if (raw is num || raw is bool) return raw.toString();
  return null;
}

/// `reason` 归一成 [WorkspaceSyncReviewReason]；缺失时为 null。
///
/// 与 `_string` 的区别：**缺失**（null）与**未知值**必须能区分——前者是
/// 「服务端没填」，后者是「服务端新增了原因」，后者要保留成
/// [WorkspaceSyncReviewReason.unknown] 而不是丢掉。
WorkspaceSyncReviewReason? _reason(Object? raw) {
  if (raw == null) return null;
  return WorkspaceSyncReviewReason.fromWire(raw);
}
