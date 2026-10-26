import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

/// 对话（group）管理动作。
///
/// ## 为什么用 sealed class 而不是 `enum` + 一个可选的 title 参数
///
/// 只有「重命名」需要携带数据（新标题）。用 `enum` 就得把回调签名写成
/// `(GroupActionKind kind, ChatGroup group, String? title)`——于是「归档」也带着
/// 一个永远为 null 的 `title`，调用方无法在编译期知道哪些动作有标题，只能靠
/// 注释。sealed class 让每个动作自带其数据。
///
/// 且 `switch` 是**穷举**的：将来新增动作时，所有 `switch` 会立刻编译报错，
/// 而不是在运行时静默走进 `default` 分支（那正是「加了功能但没人调用」的成因）。
sealed class GroupAction {
  const GroupAction();
}

/// 重命名（`PATCH /chat/groups/:id` 的 `title`）。
final class RenameGroup extends GroupAction {
  const RenameGroup(this.title);

  /// 新标题。调用方负责 trim 与「非空」校验。
  final String title;
}

/// 归档（`POST /chat/groups/:id/archive`）。
///
/// 归档是**软归档**：保留历史 turn / embedding，只是移出活跃列表且不再接收新消息。
final class ArchiveGroup extends GroupAction {
  const ArchiveGroup();
}

/// 取消归档（`POST /chat/groups/:id/unarchive`）。
final class UnarchiveGroup extends GroupAction {
  const UnarchiveGroup();
}

/// 删除（`DELETE /chat/groups/:id`）。
///
/// ⚠️ **不可恢复**（服务端是 `DELETE FROM chat_groups`，非软删）。页面必须在
/// 执行前弹确认框。
final class DeleteGroup extends GroupAction {
  const DeleteGroup();
}

/// 下载归档结项快照的正文（markdown / html）。
///
/// ## 为什么是 [GroupAction] 而不是独立回调
///
/// 它和归档/改名一样是「针对这个 group 的一次用户动作」，走同一条
/// [GroupActionHandler] 通道即可复用忙碌态、错误提示与列表刷新逻辑。
/// 单独开一条回调链会让页面多一个透传参数，且装配层要重复一遍
/// 「忙碌中禁用」的编排。
///
/// ## 执行结果的特殊性
///
/// 下载**不改服务端状态**，故 [GroupManagementUseCase] 不返回新的 group。
/// 字节通过 [SnapshotDownloadResult] 单独承载——把它塞进
/// [GroupActionApplied.group] 会让「权威状态」与「文件内容」混在一起。
final class DownloadSnapshot extends GroupAction {
  const DownloadSnapshot(this.snapshotId, this.format);

  final String snapshotId;

  /// `markdown` / `html`。与 Go 路由段一致（`.../:snapshot_id/markdown`）。
  final String format;
}

/// 重新部署快照站点（UFS 重启后恢复、改了站点源想重编译）。
///
/// ⚠️ 结果可能是 `pending` / `none`——那是 202 语义（动作已接受、稍后可见），
/// 不是失败。见 [SnapshotSiteActionResult]。
final class RedeploySnapshotSite extends GroupAction {
  const RedeploySnapshotSite(this.snapshotId);

  final String snapshotId;
}

/// 公开快照站点（staging → production）。
///
/// ⚠️ **不可逆的对外动作**：发布后任何人拿到 URL 就能读，而快照含对话摘要与
/// 工作区结构。UI 必须二次确认。
final class PublishSnapshotSite extends GroupAction {
  const PublishSnapshotSite(this.snapshotId);

  final String snapshotId;
}

/// 动作执行结果。
///
/// ## 为什么成功也要有返回对象（而不是「不抛异常 = 成功」）
///
/// 页面在成功时需要知道「本地条目该换成什么」（改名后的新标题、归档后的新状态、
/// 删除后要移除）。只靠「没抛异常」拿不到这些信息。
///
/// ## 为什么失败是一个**值**而不是异常
///
/// 「服务端拒绝了这个操作」（如删除一个已被别处删掉的 group → 404）是**预期内
/// 的业务结果**，页面只需提示；而「网络断了 / 响应无法解析」才是异常。把两者
/// 混在一起会逼页面用 `catch` 处理正常的业务分支。
///
/// [GroupActionRejected] 只表示前者；后者仍以 `SpbError` 抛出（页面同时接住）。
sealed class GroupActionResult {
  const GroupActionResult();
}

/// 服务端已接受该动作。
final class GroupActionApplied extends GroupActionResult {
  const GroupActionApplied({this.group});

  /// 服务端返回的**权威**最新状态。
  ///
  /// `null` 表示「该对话已不存在」（删除成功）。
  ///
  /// ## 为什么可能为 null：两个端点的响应形状不同
  ///
  /// `archive` / `unarchive` 返回 `{"group": {...}, "status": "..."}`，故能直接
  /// 解析出权威对象；而 `PATCH` 只返回 `{"updated": true}`（**没有** group），
  /// `DELETE` 只返回 `{"deleted": true}`。
  ///
  /// 对 PATCH 而言，若照 `ChatGroup.fromJson({updated: true})` 解析，会得到一个
  /// **字段全空的 ChatGroup**（`id: ''`、`title: ''`）——把它写回列表会让该条目
  /// 变成空白行。故 [GroupManagementUseCase] 在 PATCH 后**重新 GET 一次**拿权威
  /// 对象（`GET /chat/groups/:id` 不按 status 过滤，归档后仍可读到）。
  final ChatGroup? group;
}

/// 服务端明确拒绝（业务失败，非网络错误）。
final class GroupActionRejected extends GroupActionResult {
  const GroupActionRejected(this.message);

  /// 可直接展示给用户的原因（已整理成人话）。
  final String message;
}

/// 快照下载成功：字节 + 建议文件名。
///
/// ## 为什么带文件名
///
/// 服务端在 `Content-Disposition` 里给了 `archive-{短id}-v{n}.md`，但
/// dio 拿字节时没解析该头（见 `ChatApi._downloadSnapshot`）。客户端若要落盘
/// 需要一个名字，用「group 标题 + 版本 + 格式」拼即可——服务端文件名里的
/// 短 id 对用户毫无意义。
///
/// 文件名由**调用方**（装配层）决定最终落盘路径，本对象只给建议。
final class SnapshotDownloaded extends GroupActionResult {
  const SnapshotDownloaded({
    required this.bytes,
    required this.format,
    required this.suggestedFileName,
  });

  final List<int> bytes;

  /// `markdown` / `html`。
  final String format;

  final String suggestedFileName;
}

/// 站点动作成功（redeploy / publish）。
///
/// 注意 [action] 可能是 `ready` / `pending` / `none`——后两者是 202 语义，
/// 调用方应刷新列表等待推进，而不是报错。
final class SnapshotSiteActionApplied extends GroupActionResult {
  const SnapshotSiteActionApplied(this.result);

  final ArchiveSnapshotSiteAction result;
}

/// 管理动作的执行入口签名（供页面注入）。
///
/// ## 为什么要有这个 typedef
///
/// 页面（`spb_features`）与 app 装配层都要引用这个签名。若各处手写
/// `Future<GroupActionResult> Function(ChatGroup, GroupAction)`，则每次改签名
/// （如将来加一个「是否确认」参数）都要同步改多处，漏一处就是编译错误——而
/// 名字相同的结构化类型在 Dart 里**不会**互相报错，只会静默不兼容。
///
/// 有名字后，签名只有一处定义，其余位置引用这个名字。
typedef GroupActionHandler = Future<GroupActionResult> Function(
  ChatGroup group,
  GroupAction action,
);

/// 对话管理用例：把 [GroupAction] 翻译成 `ChatApi` 调用并归一化结果。
///
/// ## 为什么放在 domain 而不是页面里
///
/// 「哪个动作打哪个端点」「哪些失败算业务拒绝、哪些算异常」「PATCH 之后要不要
/// 补一次 GET」都是**领域规则**，不是渲染逻辑。放在 domain 后可以无头单测
/// （`dart test`，不需要 Flutter 引擎），且两个 app 共用同一份语义。
///
/// 页面（`spb_features`）只负责收集用户意图并把结果反映到列表上。
class GroupManagementUseCase {
  GroupManagementUseCase(this._api);

  final ChatApi _api;

  /// 执行动作。
  ///
  /// 抛出 [SpbError] 表示网络/解析失败；返回 [GroupActionRejected] 表示服务端
  /// 明确拒绝。
  Future<GroupActionResult> execute(ChatGroup group, GroupAction action) async {
    try {
      switch (action) {
        case RenameGroup(:final title):
          await _api.patchGroup(group.id, title: title);
          // PATCH 只回 {"updated": true}，拿不到权威对象，故补一次 GET。
          return GroupActionApplied(group: await _reload(group));

        case ArchiveGroup():
          return GroupActionApplied(group: await _setArchived(group, true));

        case UnarchiveGroup():
          return GroupActionApplied(group: await _setArchived(group, false));

        case DeleteGroup():
          await _api.deleteGroup(group.id);
          // 删除成功：group 为 null 表示「本地条目应被移除」。
          return const GroupActionApplied();

        case DownloadSnapshot(:final snapshotId, :final format):
          // 不改服务端状态，故不 reload——下载后列表无需刷新。
          final bytes = format == 'html'
              ? await _api.downloadSnapshotHtml(group.id, snapshotId)
              : await _api.downloadSnapshotMarkdown(group.id, snapshotId);
          return SnapshotDownloaded(
            bytes: bytes,
            format: format,
            suggestedFileName: _snapshotFileName(group, format),
          );

        case RedeploySnapshotSite(:final snapshotId):
          return SnapshotSiteActionApplied(
            await _api.redeploySnapshotSite(group.id, snapshotId),
          );

        case PublishSnapshotSite(:final snapshotId):
          return SnapshotSiteActionApplied(
            await _api.publishSnapshotSite(group.id, snapshotId),
          );
      }
    } on SpbError catch (e) {
      // 只有「资源已不存在」才降级为业务拒绝——此时目标状态**已经达成**
      // （用户想删的东西确实没了），提示失败反而误导。
      //
      // 其他错误（403 / 500 / 网络）仍抛出：它们是「操作可能没生效」，
      // 页面应显示错误而不是假装成功。
      if (e is HttpError && e.isNotFound) {
        SpbLog.info('group 已不存在，动作视为已完成', {
          'groupId': group.id,
          'action': action.runtimeType.toString(),
        });
        // 删除：目标达成（已不存在）→ 通知页面移除条目。
        // 改名/归档：目标**未**达成（改名没改上），但资源也没了，
        // 提示「失败」无意义——同样移除条目，因为它确实不存在了。
        return const GroupActionApplied();
      }
      rethrow;
    }
  }

  /// 归档 / 取消归档：端点直接返回权威 group。
  Future<ChatGroup> _setArchived(ChatGroup group, bool archived) async {
    if (archived) {
      await _api.archiveGroup(group.id);
    } else {
      await _api.unarchiveGroup(group.id);
    }
    // 归档端点返回 {"group": {...}}，但为了统一（且防止将来端点改回
    // {"updated": true} 时静默产出空对象），这里也走一次 GET。
    return _reload(group);
  }

  /// 重新拉取权威状态。
  ///
  /// ## 为什么不让调用方直接用端点返回值
  ///
  /// 三个写端点的响应形状不一致（见 [GroupActionApplied.group]）。统一用 GET
  /// 重新读，可以少一条「端点 A 返回对象、端点 B 只返回布尔」的分支，也顺带
  /// 拿到服务端在 `updated_at` 上的真实值。
  ///
  /// 多一次往返的代价可接受：这是用户主动触发的低频动作（不是每帧路径）。
  Future<ChatGroup> _reload(ChatGroup group) => _api.getGroup(group.id);

  /// 建议的下载文件名。
  ///
  /// 不用服务端的 `archive-{短id}-v{n}.md`：短 id 是 group id 前 8 位，对用户
  /// 没有意义。用 group 标题 + 版本号更好认，同时去掉文件系统不接受的字符。
  static String _snapshotFileName(ChatGroup group, String format) {
    final ext = format == 'html' ? 'html' : 'md';
    final title = group.title.trim();
    // 空标题（服务端兜底失败）时退化成 id，避免产出 ".md" 这种无名文件。
    final base = title.isEmpty ? group.id : title;
    final safe = base.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    final version = group.archiveSnapshot?.version ?? 1;
    return 'archive-$safe-v$version.$ext';
  }
}
