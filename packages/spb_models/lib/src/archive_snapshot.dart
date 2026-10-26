/// 归档结项快照（Archive Snapshot）摘要。
///
/// 对应 Go 侧 `archiveSnapshotDTO`（`internal/server/archive_snapshot_dto.go`）
/// 嵌进 group DTO 的 `archive_snapshot` 子对象。
///
/// ## 键名一律 snake_case
///
/// 与 [ChatGroup] 同一约定（服务端沿用 Python 版历史，**不要试图统一**成
/// camelCase）。改这里必须同步改 Go 侧 DTO，否则表现为「字段永远是默认值」
/// 而不报错。
///
/// ## 与 Go DTO 的字段对应
///
/// | 本类字段 | Go DTO 键 | 说明 |
/// |----------|-----------|------|
/// | [id] | `id` | 快照行 id（同一 group 多轮归档各有自己的 id） |
/// | [version] | `version` | 该 group 的第几次归档（归档→恢复→再归档会递增） |
/// | [status] | `status` | `pending` / `ready` / `failed` |
/// | [archiveReason] | `archive_reason` | `explicit` / `completed` / `stopped` / `manual` |
/// | [summary] | `summary` | 列表页展示的前 200 字摘要 |
/// | [createdAt] | `created_at` | 生成时刻 |
/// | [downloadAvailable] | `download_available` | 后端推导：ready 且 md/html 至少一个 |
/// | [site] | `site` | 站点信息子对象（**始终存在**） |
/// | [links] | `links` | 下载路径（仅在 ready 时给出，可能只含一种格式） |
///
/// ## 为什么 `download_available` / `links` 由后端给而不在客户端推导
///
/// 「什么时候能下载」是状态规则（ready + 至少一个 file id）。客户端复制一套
/// 迟早与服务端漂移，且漂移时**不报错**——只会表现为按钮点了 409。故推导
/// 放后端，客户端只读结果。
class ArchiveSnapshot {
  const ArchiveSnapshot({
    required this.id,
    required this.version,
    required this.status,
    required this.archiveReason,
    required this.downloadAvailable,
    required this.site,
    this.summary,
    this.createdAt,
    this.links,
  });

  final String id;
  final int version;

  /// `pending`（已建行、正文未落 UFS）/ `ready`（完整）/ `failed`（生成失败）。
  final String status;

  /// `explicit` / `completed` / `stopped` / `manual`。
  final String archiveReason;

  final String? summary;
  final DateTime? createdAt;

  /// 正文是否可下载（后端推导：`status == ready` 且 md/html 至少有一个）。
  final bool downloadAvailable;

  /// 站点信息。**始终非 null**——服务端保证 `site` 子对象存在（status 至少
  /// 是 `none`）。用 null 表示「站点没做」会让「站点在做」与「没有站点」
  /// 无法区分。
  final ArchiveSnapshotSite site;

  /// 下载路径（相对 API base）。
  ///
  /// 缺某格式时该键不存在——与 Go 侧一致（「死链接比不给更糟」）。
  final ArchiveSnapshotLinks? links;

  bool get isPending => status == 'pending';
  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';

  /// 是否至少有一种可下载格式。
  bool get hasDownloadLink => links?.any ?? false;

  factory ArchiveSnapshot.fromJson(Map<String, dynamic> json) =>
      ArchiveSnapshot(
        id: (json['id'] as String?) ?? '',
        version: _asInt(json['version']),
        status: (json['status'] as String?) ?? 'pending',
        archiveReason: (json['archive_reason'] as String?) ?? 'explicit',
        summary: json['summary'] as String?,
        createdAt: _date(json['created_at']),
        downloadAvailable: json['download_available'] == true,
        site: ArchiveSnapshotSite.fromJson(_asMap(json['site'])),
        links: ArchiveSnapshotLinks.maybeFromJson(json['links']),
      );

  /// 序列化回服务端 JSON 形态（**本地缓存用**）。
  ///
  /// ⚠️ 必须与 [fromJson] 逐字对称。不对称会表现为「缓存写进去、读出来字段
  /// 全丢」，而**不会报错**（`fromJson` 对缺失键给默认值）。`chat_group_test.dart`
  /// 的 round-trip 用例守着这条。
  Map<String, dynamic> toJson() => {
    'id': id,
    'version': version,
    'status': status,
    'archive_reason': archiveReason,
    if (summary != null) 'summary': summary,
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
    'download_available': downloadAvailable,
    'site': site.toJson(),
    if (links != null) 'links': links!.toJson(),
  };

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return const {};
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _date(Object? v) {
    final raw = v as String?;
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }
}

/// 快照的静态站点信息（设计文档 §13）。
///
/// 站点是**附加能力**：正文 ready 但站点 failed 是常见组合（UFS 渲染失败、
/// 重启卡 rendering），此时用户仍能下载 md/html。故 [status] 与
/// [ArchiveSnapshot.status] 正交，不要用前者推断后者。
class ArchiveSnapshotSite {
  const ArchiveSnapshotSite({required this.status, this.slug, this.accessUrl});

  /// `none`（从未建）/ `pending`（渲染中）/ `ready` / `failed`。
  final String status;

  /// UFS 站点 slug（`g-{group_id}`）。改名会破坏稳定 URL，故多轮归档复用同一 slug。
  final String? slug;

  /// 站点访问 URL。
  ///
  /// ⚠️ **可能是相对路径**（后端未配置 `ARCHIVE_SNAPSHOT_SITE_BASE_URL` 时落
  /// `/_staging/ufs_sites/{slug}/`）。调用方必须按当前 origin 补全，**不能
  /// 硬编码域名**——同一份客户端也连测试与预发环境。
  final String? accessUrl;

  bool get isReady => status == 'ready';
  bool get isPending => status == 'pending';
  bool get isFailed => status == 'failed';
  bool get isNone => status == 'none';

  /// 是否可打开站点（ready 且有 URL）。
  bool get isOpenable => isReady && (accessUrl?.isNotEmpty ?? false);

  factory ArchiveSnapshotSite.fromJson(Map<String, dynamic> json) =>
      ArchiveSnapshotSite(
        status: (json['status'] as String?) ?? 'none',
        slug: json['slug'] as String?,
        accessUrl: json['access_url'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'status': status,
    if (slug != null) 'slug': slug,
    if (accessUrl != null) 'access_url': accessUrl,
  };
}

/// 快照正文的下载路径（相对 API base，由调用方拼 host）。
///
/// 两种格式分别可缺：渲染 html 失败但 md 成功时只有 markdown。
/// 「死链接比不给更糟」，故缺失的格式直接不出现，而不是给空串。
class ArchiveSnapshotLinks {
  const ArchiveSnapshotLinks({this.markdown, this.html});

  /// `GET {base}{markdown}` → 快照全文 markdown。
  final String? markdown;

  /// `GET {base}{html}` → 自包含 HTML（单文件，含内联样式）。
  final String? html;

  bool get any =>
      (markdown?.isNotEmpty ?? false) || (html?.isNotEmpty ?? false);

  static ArchiveSnapshotLinks? maybeFromJson(Object? v) {
    if (v is! Map) return null;
    final m = Map<String, dynamic>.from(v);
    final links = ArchiveSnapshotLinks(
      markdown: m['markdown'] as String?,
      html: m['html'] as String?,
    );
    // 空对象等价于「没有 links」，归一成 null 让调用方只需判空一次。
    return links.any ? links : null;
  }

  Map<String, dynamic> toJson() => {
    if (markdown != null) 'markdown': markdown,
    if (html != null) 'html': html,
  };
}

/// 站点动作（redeploy / publish）的响应。
///
/// 对应 Go `archive_site.go` 的三条返回路径：
/// - `{site_id, site_status: "ready", access_url, environment}` —— 已完成
/// - `{site_id, site_status: "pending"}` —— 渲染仍在进行（**不是错误**）
/// - `{site_status: "none"}` —— 站点从未建成，已重置待 worker 重建（**不是错误**）
///
/// ## 为什么把 pending / none 当正常返回而不是异常
///
/// 服务端对这两种情况都返回 2xx：它们表示「动作已被接受，结果稍后可见」，
/// 与 409（快照正文未 ready，动作被拒绝）语义完全不同。调用方应刷新列表
/// 观察状态推进，而不是弹错误。
class ArchiveSnapshotSiteAction {
  const ArchiveSnapshotSiteAction({
    required this.siteStatus,
    this.siteId,
    this.accessUrl,
    this.environment,
  });

  /// 动作后的站点状态：`ready` / `pending` / `none`。
  final String siteStatus;

  final String? siteId;

  /// 站点 URL。可能为**相对路径**（同 [ArchiveSnapshotSite.accessUrl]）。
  final String? accessUrl;

  /// `staging` / `production`。publish 成功后为 production。
  final String? environment;

  bool get isReady => siteStatus == 'ready';

  /// 渲染仍在进行（202 语义）：应刷新列表等待，不是错误。
  bool get isPending => siteStatus == 'pending';

  /// 站点从未建成、已重置待重建（202 语义）：同上。
  bool get isReset => siteStatus == 'none';

  factory ArchiveSnapshotSiteAction.fromJson(Map<String, dynamic> json) =>
      ArchiveSnapshotSiteAction(
        siteStatus: (json['site_status'] as String?) ?? 'none',
        siteId: json['site_id'] as String?,
        accessUrl: json['access_url'] as String?,
        environment: json['environment'] as String?,
      );
}
