/// groupsync「待确认同步项」契约。
///
/// 对应 Go 侧 `internal/workers/groupsync/control.go` 的 `SyncReview`
/// 与 `internal/server/workspace_sync_reviews.go` 的两个端点：
///
/// | 方法 | 路径 | 用途 |
/// |---|---|---|
/// | GET | `/chat/groups/:gid/workspace-sync/reviews` | 列出本 group 被挂起的文件集合 |
/// | POST | `/chat/groups/:gid/workspace-sync/reviews/resolve` | 确认「同步」或「忽略」 |
///
/// ## 为什么这是**另一条**确认通道（不是 `confirmation_required`）
///
/// `confirmation_required` 是 agent 侧「要不要继续跑」的确认卡（走
/// `chat_confirmations` 表 + SSE）。本文件的 `SyncReview` 是**文件同步 worker**
/// 自己的挂起队列：目录待同步文件数 / 总量 / 突增数超过阈值、或单文件超过上限时，
/// worker **不派发上传**，把这些文件按目录或按文件挂起，等人工确认。
///
/// 两者没有任何关联，**不能**用确认卡那套端点处理。服务端只为它发一条
/// `todo.changed`（Transient，见 `EventTypes.todoChanged`），那只是「清单过期了」
/// 的失效通知，**不携带任何 review 数据**——列表仍只能靠 GET。本仓的消费方
/// （设置页 `WorkspaceSyncReviewsSection`）收到事件就重拉一次，同时保留轮询
/// 作兜底（事件会丢，见 `spb_domain/workspace_sync_reviews.dart`）。
///
/// ## 字段名是 snake_case
///
/// 服务端 `SyncReview` 结构体带 json tag，直接照抄（与 `ChatGroup` 同一约定），
/// 映射只在客户端做。
library;

/// 待确认项的**原因**（服务端 `reason` 字段）。
///
/// 阈值来自服务端 config，客户端**不复制**这些数字：默认 10 MiB 单文件 /
/// 500 文件 / 100 MiB 单目录 / 200 文件突增窗口，但都可以按部署覆盖，
/// 写死会让提示与实际行为不一致。
enum WorkspaceSyncReviewReason {
  /// 单文件超过 `GROUPSYNC_MAX_FILE_SIZE_BYTES`。
  fileTooLarge('file_too_large', '文件超过单文件上限'),

  /// 同一目录待同步文件数超过 `GROUPSYNC_MAX_BATCH_FILES`。
  tooManyFiles('too_many_files', '待同步文件数量超过单批上限'),

  /// 短时间新增文件数超过 `GROUPSYNC_MAX_BURST_FILES`。
  fileBurst('file_burst', '短时间内新增文件过多'),

  /// 同一目录待同步总量超过 `GROUPSYNC_MAX_BATCH_BYTES`。
  batchTooLarge('batch_too_large', '待同步总量超过单批上限'),

  /// 服务端新增了本客户端还不认识的原因。
  ///
  /// 不抛异常、不丢弃该项：认不出原因也要让用户**能看到并处理**它，
  /// 否则升级服务端就会让文件静默卡住（这正是本功能要消除的症状）。
  unknown('', '需要人工确认后才会同步');

  const WorkspaceSyncReviewReason(this.wire, this.label);

  /// 服务端 `reason` 的原值。
  final String wire;

  /// 中文文案（客户端只维护这一份，UI 不再另做映射）。
  final String label;

  /// 解析服务端 `reason`；未知值退化为 [unknown]。
  static WorkspaceSyncReviewReason fromWire(Object? raw) {
    final value = raw?.toString() ?? '';
    for (final r in values) {
      if (r != unknown && r.wire == value) return r;
    }
    return unknown;
  }
}

/// 用户对一条待确认项的动作（服务端 `action`，只接受这两个值）。
enum WorkspaceSyncReviewAction {
  /// 批准这批文件上传。
  sync('sync', '同步'),

  /// 忽略：把这些文件写进基线（以后不再提示），不上传。
  ignore('ignore', '忽略');

  const WorkspaceSyncReviewAction(this.wire, this.label);

  final String wire;
  final String label;
}

/// 一条待确认的同步项。
///
/// ## [groupId] 由客户端填，不在服务端响应里
///
/// 端点按 group 查询，响应体只有 `{enabled, items}`——item 里没有 `group_id`。
/// 而 resolve 必须带 group 前缀，故聚合层（`spb_domain`）在查询时就把它填进来，
/// 而不是让 UI 再去反查「这一项属于哪个 group」。
///
/// ## [revision] 是**乐观锁**，不是版本号展示
///
/// 它是这批文件「快照」的 SHA256（key + size + mtime + generation）。用户看到列表
/// 到点按钮之间，文件集合可能已经变了（agent 又写了新文件），此时服务端回
/// **409**，客户端应刷新列表让用户按新的集合重新决定——而不是重试同一份旧列表。
class WorkspaceSyncReview {
  const WorkspaceSyncReview({
    required this.id,
    required this.path,
    required this.revision,
    this.groupId = '',
    this.directory = false,
    this.reason = WorkspaceSyncReviewReason.unknown,
    this.fileCount = 0,
    this.totalBytes = 0,
    this.samples = const [],
    this.turnId = '',
    this.attributionSource = '',
  });

  /// 挂起项 id（`file:<groupKey>` 或 `dir:<groupKey>`）。resolve 用它定位。
  final String id;

  /// 所属 group（客户端填，见类文档）。
  final String groupId;

  /// 组内相对路径；`.` 表示 workspace 根。
  final String path;

  /// 是否**目录**级挂起（true 时 [samples] 给出其中若干文件名）。
  final bool directory;

  /// 挂起原因。
  final WorkspaceSyncReviewReason reason;

  /// 涉及的文件数。
  final int fileCount;

  /// 涉及的总字节数。
  final int totalBytes;

  /// 目录级挂起时的样本文件名（服务端最多给 5 条）。
  final List<String> samples;

  /// 快照 hash（乐观锁，见类文档）。
  final String revision;

  /// 扫描时观察到的「正在跑的那一轮」（服务端 `turn_id`，可缺省）。
  ///
  /// 只用于**展示**「这批文件来自哪一轮」，**不得**据此判断文件归属：并发多轮、
  /// 后台对账、用户手动上传等场景服务端一律留空（宁可没归因也不猜，见 Go
  /// `groupsync/attribution.go`）。空串 = 没有归因，UI 不显示这一行。
  final String turnId;

  /// 归因来源（服务端 `attribution_source`，如 `scan_running_turn`）。
  ///
  /// 仅供排查；客户端不按它分支（新增取值不该让归因消失）。
  final String attributionSource;

  /// 解析一条 item。
  ///
  /// [groupId] 由调用方传入：服务端响应里没有这个字段（见类文档）。
  factory WorkspaceSyncReview.fromJson(
    Map<String, dynamic> json, {
    String groupId = '',
  }) {
    return WorkspaceSyncReview(
      id: (json['id'] as String?) ?? '',
      groupId: groupId,
      path: (json['path'] as String?) ?? '',
      directory: json['directory'] == true,
      reason: WorkspaceSyncReviewReason.fromWire(json['reason']),
      fileCount: _asInt(json['file_count']),
      totalBytes: _asInt(json['total_bytes']),
      samples: json['samples'] is List
          ? [
              for (final s in json['samples'] as List)
                if (s != null && s.toString().isNotEmpty) s.toString(),
            ]
          : const [],
      revision: (json['revision'] as String?) ?? '',
      turnId: (json['turn_id'] as String?) ?? '',
      attributionSource: (json['attribution_source'] as String?) ?? '',
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  /// 人类可读的体积（**MiB**，一位小数；`total_bytes` 按 1048576 折算）。
  ///
  /// 文案必须写 MiB：按 2^20 折算却标 MB 会让用户以为阈值比实际小 5%。
  ///
  /// 与 webapp 的 `WorkspaceSyncReviews` 同口径（`total_bytes / 1048576`），
  /// 两端对同一份数据的描述必须一致，否则用户会以为看到的是两件事。
  String get totalMegabytes => (totalBytes / 1048576).toStringAsFixed(1);
}

/// `GET .../workspace-sync/reviews` 的响应。
///
/// ## 为什么要区分 [enabled] 与「空列表」
///
/// `enabled: false` 表示服务端的 groupsync worker 没在跑（功能未启用 / 尚未就绪），
/// 端点恒返回 200 + 空 items。这与「已启用但当前没有待确认项」在 UI 上**必须**
/// 不同：前者不该展示区块（用户无从处理），后者应当什么都不显示但保持轮询。
class WorkspaceSyncReviewsPage {
  const WorkspaceSyncReviewsPage({this.enabled = false, this.items = const []});

  /// 服务端是否启用了文件同步 worker。
  final bool enabled;

  /// 待确认项。
  final List<WorkspaceSyncReview> items;

  factory WorkspaceSyncReviewsPage.fromJson(
    Map<String, dynamic> json, {
    String groupId = '',
  }) {
    final raw = json['items'];
    return WorkspaceSyncReviewsPage(
      enabled: json['enabled'] == true,
      items: raw is List
          ? [
              for (final item in raw)
                if (item is Map)
                  WorkspaceSyncReview.fromJson(
                    Map<String, dynamic>.from(item),
                    groupId: groupId,
                  ),
            ]
          : const [],
    );
  }
}
