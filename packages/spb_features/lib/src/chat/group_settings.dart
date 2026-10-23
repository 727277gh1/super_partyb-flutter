import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

/// 群设置（目标 + 三个 CAS 开关）的写用例。
///
/// ## 为什么需要这一层（而不是让两个 app 各写一遍）
///
/// 每个写操作都是**两步**：先调专用 PUT 端点，再 `GET /chat/groups/:id` 取权威
/// 状态。第二步不可省——服务端的写响应只有 `{updated: true}` / `{enabled: ...}`
/// / `{tts: ...}`，**没有** group；若照 `ChatGroup.fromJson` 解析会得到字段全空的
/// 对象（`id: ''`、`title: ''`），把它写回界面就是「设置一改，对话标题变空白」。
///
/// 两个 app（桌面端侧边栏 tab / 移动端底部弹层）都要做这两步 + 同一套错误翻译，
/// 各写一遍必然漂移。故与 [GroupManagementUseCase] 同构，放在 `spb_features`。
///
/// ## 为什么失败时抛 [GroupSettingsFailure] 而不是 [SpbError]
///
/// `SpbError.message` 是**给开发者看的**（`HttpError` 的消息就是 `"HTTP 400"`），
/// 直接显示给用户等于没说。翻译需要判断错误类型 + 解析服务端 `{error}`/`{message}`
/// ——这属于「本端如何呈现」的决策。用独立类型让调用方在编译期就知道
/// 「catch 这个就能拿到可直接展示的文案」。
class GroupSettingsUseCase {
  GroupSettingsUseCase(this._api);

  final ChatApi _api;

  /// 保存目标文本（空串 = 清除目标）。
  ///
  /// 服务端语义是「goal 变更 = 新建 `chat_goals` 行」，旧 active goal 自动归档；
  /// 文本与当前相同时 `ChatApi.setGroupGoal` 内部会直接返回，不建新行。
  Future<ChatGroup> saveGoal(String groupId, String goalText) =>
      _write(() => _api.setGroupGoal(groupId, goalText), groupId);

  /// 开关「自动实现目标」。
  ///
  /// ⚠️ 无目标时服务端返回 400 `goal_required`——面板已本地禁用该开关，这里是
  /// 第二道防线（例如目标在另一台设备上被清空）。
  Future<ChatGroup> toggleGoalGate(String groupId, bool enabled) =>
      _write(() => _api.setGroupGoalGate(groupId, enabled: enabled), groupId);

  /// 保存最大自动轮次（只发这一个键，`enabled` 由服务端保持原值）。
  Future<ChatGroup> saveMaxAutoTurns(String groupId, int maxAutoTurns) =>
      _write(
        () => _api.setGroupGoalGate(groupId, maxAutoTurns: maxAutoTurns),
        groupId,
      );

  /// 开关「后续提问建议」。
  Future<ChatGroup> toggleFollowUpSuggest(String groupId, bool enabled) =>
      _write(() => _api.setGroupFollowUpSuggest(groupId, enabled), groupId);

  /// 开关「习惯建议」。
  ///
  /// 走专用 CAS 端点（`PUT /chat/groups/:id/habit-suggest`），与
  /// [toggleFollowUpSuggest] 同构。**不能**走 PATCH metadata：后者是整包替换，
  /// 会连带清掉 `metadata.tts` / `follow_up_suggest` 等其它子系统的键。
  Future<ChatGroup> toggleHabitSuggest(String groupId, bool enabled) =>
      _write(() => _api.setGroupHabitSuggest(groupId, enabled), groupId);

  /// 保存语音回复配置（**只发显式传入的键**）。
  ///
  /// 见 [SaveGroupTts] 的说明：整包提交会在并发场景下回滚另一台设备的改动。
  Future<ChatGroup> saveTts(
    String groupId, {
    bool? enabled,
    bool? narrateThinking,
    String? narrationMode,
    bool? fileSummary,
  }) => _write(
    () => _api.setGroupTts(
      groupId,
      enabled: enabled,
      narrateThinking: narrateThinking,
      narrationMode: narrationMode,
      fileSummary: fileSummary,
    ),
    groupId,
  );

  /// 写 + 重新拉取权威状态。
  ///
  /// ## 为什么 reload 失败也算整体失败
  ///
  /// 「写成功但读不回来」时若返回旧对象，界面会显示**未生效**的设置，用户会
  /// 以为没保存而重复点。抛出去让调用方提示「已保存但刷新失败，请手动刷新」
  /// 比静默显示旧值诚实。
  Future<ChatGroup> _write(
    Future<void> Function() write,
    String groupId,
  ) async {
    try {
      await write();
      return await _api.getGroup(groupId);
    } on SpbError catch (e) {
      throw GroupSettingsFailure(describeGroupSettingsError(e), cause: e);
    }
  }
}

/// 群设置写操作失败（已翻译成可直接展示的文案）。
final class GroupSettingsFailure implements Exception {
  const GroupSettingsFailure(this.message, {this.cause});

  /// 可直接展示给用户的一句话。
  final String message;

  /// 原始错误（供日志/诊断，不展示）。
  final Object? cause;

  @override
  String toString() => 'GroupSettingsFailure: $message';
}

/// 把 [SpbError] 翻译成用户能看懂的一句话。
///
/// ## `goal_required` 为什么单独处理
///
/// 服务端在「开启自动实现目标但没有目标」时返回 **400**
/// `{error: "goal_required", message: "开启「自动实现目标」前请先设置目标"}`。
/// 这是**预期内的业务结果**（用户少做了一步），不是故障——提示必须给出下一步
/// 动作，而不是「保存失败」。面板已本地禁用开关，但目标可能被另一台设备清空，
/// 故这条路径仍会走到。
///
/// ## 为什么从 body 里挖 `message` / `error`
///
/// `HttpError.message` 固定是 `"HTTP 400"`，信息量在 body。服务端统一返回
/// `{error, message?}`，故先取 `message`（人类可读），再退到 `error`（机器码，
/// 至少比「HTTP 400」有信息量）。
String describeGroupSettingsError(SpbError error) {
  if (error is AuthError && error.isUnauthorized) return '登录已过期，请重新登录';
  if (error is AuthError && error.isForbidden) return '没有权限修改这个对话';
  if (error is HttpError) {
    // `goal_required` 是机器码，不一定出现在 `message` 里，故先按 body 整体匹配。
    if (error.statusCode == 400 &&
        (error.body?.contains('goal_required') ?? false)) {
      return '请先设置目标，再开启自动实现目标';
    }
    final detail = _errorDetail(error.body);
    if (error.statusCode == 400) {
      return detail.isEmpty ? '设置未被接受，请检查输入' : detail;
    }
    if (error.isForbidden) return '没有权限修改这个对话';
    if (error.isNotFound) return '这个对话已不存在，请返回列表刷新';
    if (error.isConflict) return '设置冲突，请稍后重试';
    if (error.isRateLimited) return '操作太频繁，请稍后再试';
    if (error.isServerError) return '服务端暂时不可用，请稍后重试';
    if (detail.isNotEmpty) return detail;
  }
  if (error is NetworkError) return '网络连接失败，请检查网络后重试';
  if (error is ParseError) return '服务端返回了无法识别的数据';
  return error.message;
}

/// 从错误体里取出最有用的一段文本（`message` 优先，`error` 兜底）。
///
/// ## 为什么两种形态都要认
///
/// 服务端错误体是 `{"error": "...", "message": "..."}`，但 [HttpError.body] 是
/// **序列化后的字符串**，而 `ChatApi._bodyPreview` 用的是 `data.toString()`——
/// 对 Dio 已解析成 Map 的响应体，那是 **Dart Map 字面量**（键与字符串值都不带
/// 引号），不是 JSON：
///
/// ```
/// {error: goal_required, message: 开启「自动实现目标」前请先设置目标}
/// ```
///
/// 只按 JSON 写正则会在这里匹配不到（单测里手写 JSON 字符串反而能过）——
/// 这正是本函数同时支持两种形态的原因。取不到时返回空串（调用方走通用文案）。
String _errorDetail(String? body) {
  if (body == null || body.isEmpty) return '';
  for (final key in const ['message', 'error']) {
    final value = _jsonField(body, key) ?? _bareField(body, key);
    if (value != null && value.isNotEmpty) return value;
  }
  return '';
}

/// 取 JSON 形态的字段值：`"message": "文本"`。
String? _jsonField(String body, String key) {
  final m = RegExp('["\']$key["\']\\s*:\\s*["\']([^"\']+)["\']')
      .firstMatch(body);
  return m?.group(1)?.trim();
}

/// 取 Dart Map 字面量形态的字段值：`message: 文本,` / `message: 文本}`。
String? _bareField(String body, String key) {
  final m = RegExp('(?:^|[{,\\s])$key:\\s*([^,}]+)').firstMatch(body);
  return m?.group(1)?.trim();
}
