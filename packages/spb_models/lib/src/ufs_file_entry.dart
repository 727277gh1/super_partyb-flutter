/// UFS 文件条目。
///
/// 对应 unified-file-service 的 `model.FileResponse`
/// （`internal/model/model.go`）与 `FileListResponse{items,total}`。
///
/// ## 字段名是 snake_case
///
/// UFS 是独立 Go 服务（chi + SQLite），响应结构与 PartyB Go API 无关。
/// 它统一用 snake_case（`mime_type` / `is_directory` / `updated_at`），
/// 与 `ChatEvent` 的 camelCase 不同——照抄服务端，映射在客户端做。
///
/// ## 为什么保留 [etag]
///
/// 交付物同步靠 etag 判断「内容是否变过」。**不能只用 size/mtime**：
/// 改一个字的文件 size 不变，只看 size 会漏更新。etag 是服务端权威的内容指纹。
/// 服务端在 `FileResponse.ETag` 上标了 `omitempty`，故可能缺失（此时同步逻辑
/// 退化为按 [size] 比对）。
class UfsFileEntry {
  const UfsFileEntry({
    required this.id,
    required this.path,
    required this.size,
    this.name = '',
    this.parentId,
    this.mimeType,
    this.isDirectory = false,
    this.etag,
    this.updatedAt,
    this.updatedAtRaw,
    this.createdAt,
    this.deletedAt,
    this.ownerType,
    this.ownerId,
    this.metadata,
    this.raw = const {},
  });

  /// 文件 id（`files.id`）。下载与取详情都用它。
  final String id;

  /// materialized path（如 `grp_1/reports/a.md`）。
  ///
  /// 同步时把它当**相对路径**拼到本地目录下；因此使用前必须做路径穿越校验
  /// （`../`、绝对路径）——这是安全边界，不是格式检查。
  final String path;

  /// 字节数。
  final int size;

  /// 文件名（不含目录）。
  final String name;

  /// 父目录 id。根目录下为 null。
  final String? parentId;

  /// MIME 类型。服务端用指针，可能为 null。
  final String? mimeType;

  /// 是否目录。同步只处理文件，故需要过滤。
  final bool isDirectory;

  /// 内容指纹（服务端 `ETag`，`omitempty`）。见类文档。
  final String? etag;

  /// 服务端 `updated_at`（RFC3339）。
  ///
  /// 同步游标 `updated_since` 与它比较，故**必须保留服务端原值**，
  /// 不要转成本地时区再回传（会引入偏差，导致漏文件或重复拉取）。
  final DateTime? updatedAt;

  /// 服务端 `updated_at` 的**原始字符串**（未解析）。
  ///
  /// ## 为什么不能拿 [updatedAt] 反格式化来当游标
  ///
  /// `updated_since` 要与服务端 `updated_at` 做字符串比较，而 Go 的
  /// `time.Time` 序列化为 RFC3339**纳秒**精度（`...T00:00:00.123456789Z`）。
  /// Dart 的 `DateTime` 只到微秒，解析再格式化会**丢掉后三位**，
  /// 于是游标比服务端原值略小 → 该文件每轮都重复出现（不致漏，但白跑）；
  /// 若服务端做的是严格 `>` 比较，则会**永久漏掉**该文件。
  /// 因此游标一律用这里的原始字符串。
  final String? updatedAtRaw;

  final DateTime? createdAt;

  /// 软删除时间。**非 null 表示该条目已在远端删除**。
  ///
  /// 同步感知删除**只能**靠这个字段：增量清单里「条目缺席」只表示本轮无变化，
  /// 不能推断删除（那会把所有未变化的文件都删掉）。
  final DateTime? deletedAt;

  final String? ownerType;
  final String? ownerId;

  /// 服务端 `metadata_json`（可能含同步所需的扩展信息）。
  final Map<String, dynamic>? metadata;

  /// 原始响应，保留未建模字段以备调试与将来扩展。
  final Map<String, dynamic> raw;

  /// 是否已被远端软删除。
  bool get isDeleted => deletedAt != null;

  /// 是否应被同步逻辑处理（非目录、非删除）。
  ///
  /// 注意**删除的条目也要进计划**（用于删本地副本），故这里只排除目录。
  bool get isFile => !isDirectory;

  factory UfsFileEntry.fromJson(Map<String, dynamic> json) => UfsFileEntry(
    id: (json['id'] ?? '').toString(),
    path: (json['path'] ?? '').toString(),
    size: _int(json['size']),
    name: (json['name'] ?? '').toString(),
    parentId: json['parent_id'] as String?,
    mimeType: json['mime_type'] as String?,
    isDirectory: json['is_directory'] == true,
    etag: _nonEmpty(json['etag']),
    updatedAt: _date(json['updated_at']),
    updatedAtRaw: _nonEmpty(json['updated_at']),
    createdAt: _date(json['created_at']),
    deletedAt: _date(json['deleted_at']),
    ownerType: json['owner_type'] as String?,
    ownerId: json['owner_id'] as String?,
    metadata: _asMap(json['metadata_json']),
    raw: json,
  );

  /// 空串按「未提供」处理。
  ///
  /// 服务端的 `omitempty` 在 Go 里会**整个键不出现**，但经 JSON 中转后也可能
  /// 出现空串（如手工构造的响应）。把空串归一化成 null，可以避免下游出现
  /// 「etag 存在但是空」这种需要特判的中间状态。
  static String? _nonEmpty(Object? v) {
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// 解析时间；非法/缺失返回 null（**不要**回退到 `DateTime.now()`——
  /// 那会让「没有 updated_at」的条目看起来像刚刚更新过，破坏增量语义）。
  static DateTime? _date(Object? v) {
    final s = v?.toString();
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  @override
  String toString() =>
      'UfsFileEntry($id, path=$path, size=$size, etag=$etag'
      '${isDeleted ? ', DELETED' : ''})';
}

/// `GET /api/files` 的响应（`FileListResponse`）。
///
/// UFS 用 `{items,total}`（**不是** `next_cursor`）：它是 page/page_size 分页，
/// 与 PartyB 的 timeline 游标分页不同。故这里单独建模而不是复用
/// `ListResponse`（后者只有 items，会静默丢掉 total，导致「还有下一页」判断
/// 只能靠 `items.length == pageSize` 这种脆弱推断）。
class UfsFilePage {
  const UfsFilePage({required this.items, required this.total});

  final List<UfsFileEntry> items;

  /// 服务端匹配到的**总数**（非本页条数）。据此判断是否还有下一页。
  final int total;

  bool get isEmpty => items.isEmpty;

  /// 是否还有下一页（已知 [page] 与 [pageSize] 时）。
  bool hasMore({required int page, required int pageSize}) =>
      page * pageSize < total;

  factory UfsFilePage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <UfsFileEntry>[];
    if (rawItems is List) {
      for (final e in rawItems) {
        if (e is Map) {
          items.add(UfsFileEntry.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return UfsFilePage(items: items, total: UfsFileEntry._int(json['total']));
  }

  @override
  String toString() => 'UfsFilePage(${items.length}/$total)';
}
