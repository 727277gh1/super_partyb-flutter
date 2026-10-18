import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

/// 自动续跑排程（auto-schedules）的读用例。
///
/// ## 它解决什么
///
/// 服务端为「Goal Gate 自动续跑」排了一批 `chat_turn_schedules` 行。客户端此前
/// **完全没有**这个端点的调用方——排程只写不读，用户看不到「它过一会儿还要
/// 自己接着跑几轮」，也没法取消。本用例把这条链路补完。
///
/// ## ⚠️ 为什么必须传 `agentId` 并**本地按 group 过滤**
///
/// 列出端点的 handler（Go `admin.go` 的 `listByAgent`）**忽略路径里的
/// `:group_id`**：
///
/// ```go
/// rg.GET("/:group_id/auto-schedules", h.listByAgent)   // :group_id 从未被读
/// items, _ := h.q.ListChatTurnSchedules(ctx, ...{
///     AgentID: c.Query("agent_id"), ...                // 只按 agent 查
/// })
/// ```
///
/// 而 `chat_turn_schedules` **没有 group 列**——group 只存在于
/// `policy_json.meta.group_id`。于是：
///
/// - 不传 `agentId` → `WHERE agent_id = ''` → **恒空**（看起来像「没有排程」）；
/// - 传了 `agentId` → 得到「**该 agent 的全部**排程」，可能横跨多个 group。
///
/// 故本用例做两件事：传 `agentId`（取自 [ChatGroup.activeSession]，那是服务端
/// 已判定的当前 agent），再按 [ChatTurnSchedule.groupId] 本地过滤。
/// **不补这两步，同 agent 下别的对话的排程会串进当前面板**——用户会看到并停掉
/// 不属于本对话的续跑。
///
/// ## 为什么 `stopAll` 之后**回读列表**而不是回读 group
///
/// 停用改变的是**排程集合**（哪些 `enabled` 翻成 0），不是 group 快照的任何
/// 字段——`ChatGroup` 里根本没有排程信息。若照 `GroupSettingsUseCase` 那样回读
/// group，面板拿到的仍是旧列表，用户会以为「点了没反应」而反复点。
///
/// ## 为什么失败时抛 [AutoSchedulesFailure] 而不是 [SpbError]
///
/// 同 `GroupSettingsUseCase`：`SpbError.message` 是给开发者看的
/// （`HttpError` 的消息就是 `"HTTP 400"`）。用独立类型让调用方在编译期就知道
/// 「catch 这个就能拿到可直接展示的文案」。
class AutoSchedulesUseCase {
  AutoSchedulesUseCase(this._api);

  final ChatApi _api;

  /// 列出当前 group 的排程。
  ///
  /// 取数两步：`GET /chat/groups/:id` 拿 `activeSession.agentId`，再
  /// `GET /api/chat/groups/:id/auto-schedules?agent_id=…`，最后本地过滤。
  ///
  /// 为什么每次都重新取 group 而不让调用方把 `agentId` 传进来：调用方（面板）
  /// 手上的 `ChatGroup` 可能是旧快照，而 agent 切换后旧 agentId 会查出**别的
  /// agent 的排程**（虽然会被 group 过滤挡住，但会白跑一次请求）。多一次
  /// `GET /chat/groups/:id` 换「不会拿错 agent」是划算的，且该端点本来就在
  /// 对话页的常规刷新路径上（有 HTTP 缓存语义之外的意义：它是最权威的快照）。
  Future<List<ChatTurnSchedule>> load(String groupId) async {
    try {
      final group = await _api.getGroup(groupId);
      final agentId = group.activeSession?.agentId;
      final all = await _api.listAutoSchedules(groupId, agentId: agentId);
      // 本地补回 handler 丢掉的 group 维度（见类文档）。
      //
      // ⚠️ 严格等值过滤，**不**把「取不到 groupId」的行放行。理由：停用端点的
      // SQL 是按 `policy_json.meta.group_id = ?` 过滤的，它**碰不到**这些行。
      // 若放行，一个 groupId 为 null 的 pending 行会在停用后仍留在列表里，
      // 于是「停用全部」按钮永远可点——看起来像点了没反应。宁可不显示。
      return all.where((s) => s.groupId == groupId).toList(growable: false);
    } on SpbError catch (e) {
      throw AutoSchedulesFailure(describeAutoSchedulesError(e), cause: e);
    }
  }

  /// 撤销当前 group 下全部**未触发**的 goal_gate 续跑排程，返回撤销条数。
  ///
  /// 服务端谓词是 `enabled=1 AND run_count < max_runs AND
  /// dedupe_key LIKE 'goal_gate:%' AND policy_json.meta.group_id = ?`，
  /// 故不会误伤 retry / fastpath，也不会碰别的 group。
  ///
  /// ## 为什么写完之后**回读列表**（而不是把条数返回给调用方了事）
  ///
  /// 返回条数只够写一句「已停用 N 条」，而面板上那一列条目仍显示「待触发」——
  /// 用户看到的是「按钮说停用了，列表里还在」，会怀疑没生效。故本方法在写成功
  /// 后重新 [load]，把**权威列表**作为结果返回，让调用方直接替换本地状态。
  ///
  /// ## 为什么回读失败也算整体失败
  ///
  /// 与 `GroupSettingsUseCase._write` 同一取舍：写成功但读不回来时，若静默返回
  /// 旧的「待触发」列表，用户会以为停用没生效而重复点。抛出去让调用方提示
  /// 「已停用但刷新失败」比显示假象诚实。
  Future<AutoSchedulesStopResult> stopAll(String groupId) async {
    try {
      final disabled = await _api.stopAutoSchedule(groupId);
      final items = await load(groupId);
      return AutoSchedulesStopResult(disabledCount: disabled, items: items);
    } on AutoSchedulesFailure {
      // load 已经翻译过了，别把「停用失败」的文案盖成「加载失败」。
      rethrow;
    } on SpbError catch (e) {
      throw AutoSchedulesFailure(describeAutoSchedulesError(e), cause: e);
    }
  }
}

/// [AutoSchedulesUseCase.stopAll] 的结果：撤销条数 + 回读到的权威列表。
class AutoSchedulesStopResult {
  const AutoSchedulesStopResult({
    required this.disabledCount,
    required this.items,
  });

  /// 服务端实际撤销的条数（`disabled_count`）。
  final int disabledCount;

  /// 回读到的权威列表（已本地按 group 过滤）。
  final List<ChatTurnSchedule> items;
}

/// 排程操作失败（已翻译成可直接展示的文案）。
final class AutoSchedulesFailure implements Exception {
  const AutoSchedulesFailure(this.message, {this.cause});

  /// 可直接展示给用户的一句话。
  final String message;

  /// 原始错误（供日志/诊断，不展示）。
  final Object? cause;

  @override
  String toString() => 'AutoSchedulesFailure: $message';
}

/// 把 [SpbError] 翻译成用户能看懂的一句话。
///
/// 复用 `GroupSettingsUseCase` 的翻译（同一套 `/chat/*` 端点的错误形态），
/// 但把「设置」换成「自动续跑」——文案里的名词必须与被操作的实体一致，
/// 否则用户会去找一个不存在的「设置」。
String describeAutoSchedulesError(SpbError error) {
  if (error is AuthError && error.isUnauthorized) return '登录已过期，请重新登录';
  if (error is AuthError && error.isForbidden) return '没有权限管理这个对话的自动续跑';
  if (error is HttpError) {
    if (error.isForbidden) return '没有权限管理这个对话的自动续跑';
    if (error.isNotFound) return '这个对话已不存在，请返回列表刷新';
    if (error.isConflict) return '排程状态已变化，请刷新后重试';
    if (error.isRateLimited) return '操作太频繁，请稍后再试';
    if (error.isServerError) return '服务端暂时不可用，请稍后重试';
  }
  if (error is NetworkError) return '网络连接失败，请检查网络后重试';
  if (error is ParseError) return '服务端返回了无法识别的数据';
  return error.message;
}
