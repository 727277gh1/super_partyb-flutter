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
/// ## 历史注：server 端点已修复，两步 workaround 已撤销（2026-11，Go `b2a54b5a`）
///
/// 服务端 handler 曾（`admin.go` 的 `listByAgent`）**忽略路径里的 `:group_id`**，
/// 只按 `agent_id` 查——故本用例此前要先取 group 拿 agentId、再本地按
/// [ChatTurnSchedule.groupId] 过滤，否则同 agent 下别的对话的排程会串进当前
/// 面板。Go `b2a54b5a` 重写为 `ListOwnedGroupSchedules`（按路径 `:group_id` +
/// 当前用户过滤，**忽略** `agent_id` 查询参数），现在**单次请求**即得当前
/// group 的排程，两步 workaround 已删除。
///
/// 仍保留一道 `groupId` 断言（见 [load]）——它从 workaround 升级成了**校验**：
/// 停用端点的 SQL 仍按 `policy.meta.group_id = ?` 过滤，解析不出该键的行
/// 停用端点碰不到，显示出来只会制造「点了没反应」。
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
  /// 服务端（Go `b2a54b5a` 起）按路径 `:group_id` + 当前用户过滤，
  /// **忽略** `agent_id` 查询参数——单次请求即得结果，无需再取 group 拿
  /// agentId（那段 workaround 已随服务端修复撤销，见类文档）。
  ///
  /// 仍保留一道 [ChatTurnSchedule.groupId] 断言：解析不出归属的行**不放行**。
  /// 停用端点的 SQL 按 `policy.meta.group_id = ?` 过滤，碰不到这些行；若显示
  /// 出来，「停用全部」会在它们身上永远无效——比「少显示一行」糟得多。
  Future<List<ChatTurnSchedule>> load(String groupId) async {
    try {
      final all = await _api.listAutoSchedules(groupId);
      // 校验服务端真的按 group 过滤了（见上）。严格等值，不放宽。
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
/// 但把「设置」换成「执行计划」——文案里的名词必须与被操作的实体一致，
/// 否则用户会去找一个不存在的「设置」。
String describeAutoSchedulesError(SpbError error) {
  if (error is AuthError && error.isUnauthorized) return '登录已过期，请重新登录';
  if (error is AuthError && error.isForbidden) return '没有权限管理这个对话的执行计划';
  if (error is HttpError) {
    if (error.isForbidden) return '没有权限管理这个对话的执行计划';
    if (error.isNotFound) return '这个对话已不存在，请返回列表刷新';
    if (error.isConflict) return '排程状态已变化，请刷新后重试';
    if (error.isRateLimited) return '操作太频繁，请稍后再试';
    if (error.isServerError) return '服务端暂时不可用，请稍后重试';
  }
  if (error is NetworkError) return '网络连接失败，请检查网络后重试';
  if (error is ParseError) return '服务端返回了无法识别的数据';
  return error.message;
}
