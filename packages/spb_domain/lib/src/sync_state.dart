/// 交付物同步的**状态契约**（纯 Dart，无持久化实现）。
///
/// 持久化实现见 `spb_data` 的 `DriftSyncStateStore`（依赖方向
/// `spb_data → spb_domain` 是允许的；反向不允许，故接口必须在 domain）。
///
/// ## 为什么需要本地状态
///
/// 对齐 `super_partyb/apps/desktop/src-tauri/src/sync/state.rs`：
///
/// - **增量游标**：UFS 的 `updated_since` 需要上次同步的时间点，否则退化成全量；
/// - **etag 比对**：文件内容可能变而 size 不变（改一个字），只靠 size/mtime 会
///   漏更新；etag 能反映「远端记录自上次同步后有没有被写过」；
/// - **内容 hash**：判定「本地这份还是不是远端那一份」必须用下载时算的
///   [SyncedFile.contentHash]——UFS 的 etag 是 `W/"<file_id>:<updated_at_nano>"`，
///   与内容无关，答不了这个问题（见 docs/deliverable-upload-and-conflict.md §2.1①）；
/// - **删除感知**：远端软删除的条目不会出现在本地磁盘上，只能靠状态表知道
///   「这个文件以前同步过、现在要删」。
library;

import 'package:crypto/crypto.dart' as crypto;

/// 计算内容的 SHA256（十六进制小写）。
///
/// ## 为什么放在 domain 而不是各调用点自己算
///
/// 「下载时记录 hash」（[SyncedFile.contentHash]）与「回传前比对本地是否被改」
/// 必须用**同一种**算法与编码，否则脏检测会把全部文件都判成脏的。收敛到一处，
/// 这个不变量就不依赖调用方的自觉。
String contentHashOf(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();

/// 单个已同步文件的记录。
class SyncedFile {
  const SyncedFile({
    this.etag,
    required this.size,
    this.updatedAt,
    this.contentHash,
  });

  /// 服务端内容指纹。null 表示服务端未返回（如某些 MIME），此时退化为按
  /// [size] 判断。
  final String? etag;

  /// 同步时的字节数（etag 缺失时的兜底比对依据）。
  final int size;

  /// 服务端 `updated_at` 原样保留（RFC3339 字符串），仅用于诊断与展示。
  ///
  /// 存字符串而非 `DateTime`：它是**服务端**的时间表示，转成本地 `DateTime`
  /// 会引入时区/精度改写，而它只用于展示，没有必要承担这个风险。
  final String? updatedAt;

  /// **下载时**对实际落盘字节计算的 SHA256（十六进制小写）。
  ///
  /// ## 为什么需要它（etag 答不了这个问题）
  ///
  /// 脏检测要回答的是「本地这份内容还是不是远端那一份」。UFS 的 etag 是
  /// `W/"<file_id>:<updated_at_unix_nano>"`
  /// （`unified-file-service/internal/model/model.go` 的 `GenerateETag`），
  /// 只随文件记录 ID 与更新时间变化，**与内容无关**，因此不能用它比对本地
  /// 字节。
  ///
  /// ## null 的语义（向后兼容）
  ///
  /// null = 该记录写于本字段引入之前（升级前已同步的文件），或计算失败。
  /// 此时脏检测**降级为「无法检测」**（宁可漏报也不误报）——这些文件在下次
  /// 被重新下载后会获得 hash 并纳入检测。
  final String? contentHash;

  /// 该记录是否表示「与 [etag]/[size] 描述的远端内容一致」。
  ///
  /// ## 为什么 etag 双方都存在时以 etag 为准
  ///
  /// 文件内容可能变而 size 不变（改一个字），只靠 size 会**漏更新**。
  /// etag 能反映「远端记录是否被写过」，足以决定要不要重新下载。
  ///
  /// ## 为什么任一侧缺 etag 时退化为 size 比对
  ///
  /// 服务端的 `etag` 是 `omitempty`，可能缺失。此时无法判断内容是否变过，
  /// 只能退化为 size；方向选「宁可多下一次」——多下载只是浪费流量，
  /// 漏更新会让用户拿到过期内容且不自知。
  bool matches({required String? etag, required int size}) {
    final mine = this.etag;
    if (mine != null && etag != null) return mine == etag;
    return this.size == size;
  }

  @override
  bool operator ==(Object other) =>
      other is SyncedFile &&
      other.etag == etag &&
      other.size == size &&
      other.updatedAt == updatedAt &&
      other.contentHash == contentHash;

  @override
  int get hashCode => Object.hash(etag, size, updatedAt, contentHash);

  @override
  String toString() =>
      'SyncedFile(etag: $etag, size: $size, updatedAt: $updatedAt, '
      'contentHash: $contentHash)';
}

/// 一个同步状态键（state key）下的全部状态：游标 + 各文件的 etag 记录。
class SyncState {
  const SyncState({this.cursor, this.files = const <String, SyncedFile>{}});

  /// 上次成功同步的服务端时间点（RFC3339），作为下一轮 `updated_since`。
  ///
  /// null 表示从未成功同步过 → 下一轮做全量。
  final String? cursor;

  /// 相对路径 → 记录。
  final Map<String, SyncedFile> files;

  /// 「从未同步过」的状态（无游标、无记录）。
  static const SyncState empty = SyncState();

  bool get isEmpty => cursor == null && files.isEmpty;

  /// 该相对路径是否已同步过且内容未变。
  ///
  /// 见 [SyncedFile.matches] 关于 etag/size 取舍的说明。
  /// 未知路径**一律**视为「已变更」（否则新文件会被跳过，永远不落盘）。
  bool isUnchanged(String relPath, {String? etag, required int size}) {
    final prev = files[relPath];
    if (prev == null) return false;
    return prev.matches(etag: etag, size: size);
  }

  /// 该路径是否曾被同步过（用于判断删除时本地是否有副本）。
  bool contains(String relPath) => files.containsKey(relPath);

  /// 记录一个文件已同步（**不可变**：返回新状态，不改自身）。
  ///
  /// ## 为什么 SyncState 是不可变的
  ///
  /// 同步计划是「读状态 → 算计划 → 执行 → 写回新状态」的流程。若状态可变，
  /// 计划阶段就可能被后续写入污染，而计划必须基于**执行前**的事实
  /// （否则同一轮里后处理的文件会看到前面文件的更新）。
  SyncState markSynced(
    String relPath, {
    String? etag,
    required int size,
    String? updatedAt,
    String? contentHash,
  }) => copyWith(
    files: {
      ...files,
      relPath: SyncedFile(
        etag: etag,
        size: size,
        updatedAt: updatedAt,
        contentHash: contentHash,
      ),
    },
  );

  /// 移除记录（文件已在远端删除或本地清理）。
  SyncState forget(String relPath) =>
      copyWith(files: {...files}..remove(relPath));

  /// 推进游标（**只前进，不回退**）。
  ///
  /// ## 为什么必须单调
  ///
  /// 游标是「已同步到哪」的水位线。若允许回退，一次返回较旧数据的响应
  /// （如某轮清单里最大 `updated_at` 较小）就会让下一轮重新拉取已同步区间，
  /// 白白浪费流量；更糟的是，若下游据此做了「早于游标即已同步」的推断，
  /// 回退会造成漏更新。
  ///
  /// 比较用字符串字典序：RFC3339（同为 UTC `Z`、补零到固定宽度）满足
  /// 「字典序即时序」。这是服务端约定的格式，见 UFS 的 `updated_at`。
  SyncState advanceCursor(String? candidate) {
    if (candidate == null || candidate.isEmpty) return this;
    final current = cursor;
    if (current != null && current.compareTo(candidate) >= 0) return this;
    return copyWith(cursor: candidate);
  }

  /// 复制并覆盖部分字段。
  SyncState copyWith({
    String? cursor,
    Map<String, SyncedFile>? files,
    bool clearCursor = false,
  }) => SyncState(
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    files: files ?? this.files,
  );

  @override
  bool operator ==(Object other) {
    if (other is! SyncState) return false;
    if (other.cursor != cursor) return false;
    if (other.files.length != files.length) return false;
    for (final entry in files.entries) {
      final otherFile = other.files[entry.key];
      if (otherFile == null || otherFile != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    cursor,
    Object.hashAllUnordered(
      files.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  /// 诊断用（**不含文件内容**，只给条数）。
  @override
  String toString() => 'SyncState(cursor: $cursor, files: ${files.length} 条)';
}

/// 状态键：**全部 group** 与 **选中若干 group** 共用。
///
/// 两种范围的本地落盘布局相同（都按 `{group_id}/` 分层），故状态可跨范围
/// 复用——切换范围时**不得**重置状态，否则所有文件会在下一轮全量重下。
/// 详见 `super_partyb/apps/desktop/README.md`「范围变更**不**重置同步状态」。
///
/// 单 group 模式则直接用 `group_id` 作状态键（落盘无 `{gid}/` 前缀，
/// 布局不同 → 状态必须分开）。
const String workspaceStateKey = '__workspace__';

/// 同步状态存储（key → 游标 + 各文件 etag 记录）。
///
/// ## 为什么抽象成接口
///
/// 同步**纯逻辑**（计划生成：哪些要下载/跳过/删除）在 `spb_domain`，而持久化
/// 在 `spb_data`。domain 不能依赖 data，故把契约放这里，逻辑层只依赖接口，
/// 单测可注入内存实现。
abstract interface class SyncStateStore {
  /// 读取 [key] 的状态；从未写入过时返回 [SyncState.empty]。
  Future<SyncState> load(String key);

  /// 覆盖写入 [key] 的状态（同键旧记录整体替换，不残留已消失的文件）。
  Future<void> save(String key, SyncState state);

  /// 清除单个 [key] 的状态。
  Future<void> reset(String key);

  /// 清除**全部**状态。
  ///
  /// ## 何时必须调用：用户换了同步目录
  ///
  /// 状态描述的是「某个本地目录里已有什么」，**绑定在具体目录上**：
  ///
  /// - 保留游标 → 增量清单只返回 `updated_at >= 游标` 的文件，新目录几乎什么都
  ///   拿不到；
  /// - 保留 etag → 少数恰好出现在清单里的文件被判为「未变更」而跳过写入，
  ///   但新目录里根本没有这个文件。
  ///
  /// 两者叠加就是「换目录后同步显示成功，但新目录是空的」。
  ///
  /// ## 何时**不**能调用
  ///
  /// - 清理已落盘文件时（会触发重新下载）；
  /// - **改变同步范围时**（全量/选中若干共用 [workspaceStateKey]，见其说明）。
  Future<void> resetAll();
}
