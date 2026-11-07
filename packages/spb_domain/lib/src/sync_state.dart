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

import 'dart:convert' show ChunkedConversionSink;
import 'dart:isolate' show Isolate, TransferableTypedData;
import 'dart:typed_data' show Uint8List;

import 'package:crypto/crypto.dart' as crypto;

/// 计算内容的 SHA256（十六进制小写）。
///
/// ## 为什么放在 domain 而不是各调用点自己算
///
/// 「下载时记录 hash」（[SyncedFile.contentHash]）与「回传前比对本地是否被改」
/// 必须用**同一种**算法与编码，否则脏检测会把全部文件都判成脏的。收敛到一处，
/// 这个不变量就不依赖调用方的自觉。
///
/// ## 为什么不再被生产代码调用（docs/memory-audit.md G6）
///
/// 本函数在**当前 isolate** 同步跑完整段 SHA256。同步下载（几 MB 到上百 MB）
/// 与回传脏检测都会经它：200MB ≈ 0.4s（SHA256 吞吐 ~500MB/s），期间**整个
/// UI 冻结**（构建/滚动/流式全停）。生产代码一律改用 [contentHashOfAsync]
/// （`Isolate.run`，大输入不占 UI 线程）。本函数保留给：
///
/// 1. 测试（已知向量、确定性断言）；
/// 2. [contentHashOfAsync] 自身的回退路径；
/// 3. 「两条路径必须产出同一 hash」这个不变量的同源保证——异步版复用它，
///    算法/编码漂移在结构上不可能。
String contentHashOf(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();

/// 在后台 isolate 计算 SHA256（十六进制小写，与 [contentHashOf] 同一编码）。
///
/// ## 为什么要有它（docs/memory-audit.md G6）
///
/// 生产链路（下载落盘前的 hash、回传脏检测）此前都在 UI isolate 同步哈希
/// 全量字节——同步一轮 5666 文件、或单个大视频，都会把 UI 冻住数百毫秒到
/// 数秒。改走 `Isolate.run` 后：主 isolate 只付 isolate 启动（~1ms）与
/// `TransferableTypedData` 物化（一次 memcpy）的成本，哈希本体在 worker。
///
/// ## `TransferableTypedData` 的作用（**不是**所有权转移）
///
/// 直接 `Isolate.run(() => sha256.convert(bytes))` 时，[bytes] 作为闭包捕获
/// 量会在**发送消息**那一刻被整份拷贝进 worker。
/// `TransferableTypedData.fromList` 把字节拷进一块**外部缓冲**，随后发送
/// 消息与 worker 侧 `materialize()` 都不再拷贝——worker 拿到的是外部内存
/// 视图，不占它的 Dart 堆。
///
/// ⚠️ **`fromList` 自己就拷贝一次**（实测：`fromList` 之后改原 buffer，
/// `materialize()` 出来的字节不受影响），所以：
///
/// - 本函数**不改变** [bytes] 的内容，调用方仍可继续读它——不存在「转移后
///   失效」的约束（曾误以为有，注释已纠正）；
/// - 收益不是「少一次拷贝」，而是「worker 侧零拷贝 + 不产生堆分配」：对
///   大文件避免的是 worker 的堆峰值与 GC 压力，UI isolate 的收益来自
///   「哈希不再占用它」，与这里无关。
///
/// 空/小输入（< 8KB）直接在当前 isolate 算：isolate 启动 + 一次拷贝的成本
/// 反而高于哈希本身，不划算。
///
/// ## 失败降级
///
/// `Isolate.run` 在某些受限环境（旧版 web/测试 host）可能抛
/// `UnsupportedError`。此时回退到主 isolate 的 [contentHashOf]——慢但不坏，
/// 与「图片解码失败不阻断卡片」同一取向。
Future<String> contentHashOfAsync(List<int> bytes) async {
  // 小输入不值得开 isolate：8KB 的 SHA256 ~15µs，而 isolate 往返 ~1ms+。
  const smallInputThreshold = 8 * 1024;
  if (bytes.length < smallInputThreshold) return contentHashOf(bytes);
  try {
    final transferable = TransferableTypedData.fromList([
      if (bytes is Uint8List) bytes else Uint8List.fromList(bytes),
    ]);
    return await Isolate.run(
      () => contentHashOf(transferable.materialize().asUint8List()),
    );
  } on UnsupportedError {
    // 受限环境（无 isolate 支持）：回退主 isolate，行为与旧版一致。
    return contentHashOf(bytes);
  }
}

/// **流式**算 SHA256（十六进制小写）：峰值内存 O(单块)，与文件大小无关。
///
/// ## 为什么需要它（2026-11 真机实测的 ~240MB 瞬时尖峰）
///
/// 回传脏检测此前是「`LocalFileReader.readBytes` 整份读入 →
/// [contentHashOfAsync] 再拷一份」（`TransferableTypedData.fromList` 自己就
/// 会拷贝，见其文档），即**瞬时 ≈ 2× 文件大小**。真实用户机器（Windows，
/// 同步目录 5666 个文件）在登录后首次脏检测时打出
/// `rss 258MB → 498.5MB，9 秒后回落到 287MB`——那份拷贝，不是泄漏。
///
/// 本函数让调用方把 `File.openRead()` 这类**块流**喂进来：`HashSink` 内部只
/// 累积摘要状态，每块处理完即可释放，峰值 ≈ 块大小（dart:io 默认 64KB）。
///
/// ## 与 [contentHashOfAsync] 的分工（**不可互换**）
///
/// - 手上已有**整份字节**（网络响应已在内存里）：用 [contentHashOfAsync]，
///   在 isolate 里算，不冻 UI；
/// - 手上是**文件路径**：用本函数（经 `LocalFileReader.contentDigestOf`），
///   连读带算都不驻留整份内容，`await for` 之间还能让出事件循环。
///
/// 两者必须给出**同一个**摘要——脏检测拿它与 [SyncedFile.contentHash] 比对，
/// 算法或编码不一致会把全部文件误判成「用户改动过」。故这里同样用
/// [crypto.sha256] 与 `Digest.toString()`（即小写十六进制）。
Future<String> contentHashOfStream(Stream<List<int>> chunks) async {
  crypto.Digest? digest;
  final sink = crypto.sha256.startChunkedConversion(
    ChunkedConversionSink<crypto.Digest>.withCallback(
      (out) => digest = out.single,
    ),
  );
  await for (final chunk in chunks) {
    sink.add(chunk);
  }
  sink.close();
  final result = digest;
  if (result == null) {
    // 正常路径不可能到这里（`close()` 一定产出摘要）。显式抛错而不是返回
    // 空串：空串会被脏检测当成「与基准不同」→ 整目录误判为改动。
    throw StateError('SHA256 分块计算未产出摘要');
  }
  return result.toString();
}

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
  const SyncState({
    this.cursor,
    this.files = const <String, SyncedFile>{},
    this.failures = const <String, SyncFailureRecord>{},
  });

  /// 上次成功同步的服务端时间点（RFC3339），作为下一轮 `updated_since`。
  ///
  /// null 表示从未成功同步过 → 下一轮做全量。
  final String? cursor;

  /// 相对路径 → 记录。
  final Map<String, SyncedFile> files;

  /// 持续失败文件的隔离记录（issue #64）：相对路径 → 连续失败次数 + 最近错误。
  ///
  /// 与 [files] 正交：失败项不在 [files] 里（不变量：成功才写状态），这里
  /// 只记「还没同步成过、且连续失败」的。成功一轮即移除（自动解除隔离）。
  /// 必须持久化：内存计数在进程重启后清零，定时同步下隔离永不生效。
  final Map<String, SyncFailureRecord> failures;

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

  /// 记一次失败（**不可变**：返回新状态），连续失败则次数 +1（issue #64）。
  ///
  /// [updatedAt] 是失败时该文件的远端 `updated_at`：隔离后游标要推过它，
  /// 否则下一轮清单仍会返回这个文件，隔离白做。
  SyncState markFailure(String relPath, String reason, {String? updatedAt}) {
    final prev = failures[relPath];
    return copyWith(
      failures: {
        ...failures,
        relPath: SyncFailureRecord(
          count: (prev?.count ?? 0) + 1,
          lastError: reason,
          updatedAt: updatedAt ?? prev?.updatedAt,
        ),
      },
    );
  }

  /// 清除失败记录（成功/删除成功/远端不再返回时调用）。
  ///
  /// 这就是隔离名单的**自动解除**：一次成功即重新纳入正常轮转。
  SyncState clearFailure(String relPath) {
    if (!failures.containsKey(relPath)) return this;
    return copyWith(failures: {...failures}..remove(relPath));
  }

  /// 该路径是否已达隔离阈值（连续失败 [quarantineAfterFailures] 次）。
  bool isQuarantined(
    String relPath, {
    int quarantineAfter = quarantineAfterFailures,
  }) {
    final f = failures[relPath];
    return f != null && f.count >= quarantineAfter;
  }

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
    Map<String, SyncFailureRecord>? failures,
    bool clearCursor = false,
  }) => SyncState(
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    files: files ?? this.files,
    failures: failures ?? this.failures,
  );

  @override
  bool operator ==(Object other) {
    if (other is! SyncState) return false;
    if (other.cursor != cursor) return false;
    if (other.files.length != files.length) return false;
    if (other.failures.length != failures.length) return false;
    for (final entry in files.entries) {
      final otherFile = other.files[entry.key];
      if (otherFile == null || otherFile != entry.value) return false;
    }
    for (final entry in failures.entries) {
      final otherFailure = other.failures[entry.key];
      if (otherFailure == null || otherFailure != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    cursor,
    Object.hashAllUnordered(
      files.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      failures.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  /// 诊断用（**不含文件内容**，只给条数）。
  @override
  String toString() =>
      'SyncState(cursor: $cursor, files: ${files.length} 条, '
      'failures: ${failures.length} 条)';
}

/// 隔离阈值（issue #64）：同一文件连续失败这么多次后，允许游标越过它。
///
/// 前 N-1 轮保守（不推进，维持「失败不推进」的漏文件保护）；达到阈值后
/// 判定为**持续性**失败（403 无权限 / 路径非法 / 服务端对该文件恒 500），
/// 不再让它拖住整个 workspace。网络抖动几乎不可能连续命中同一文件 N 次。
const int quarantineAfterFailures = 3;

/// 单个文件的连续失败记录（持久化到 sync.db，跨进程累计）。
class SyncFailureRecord {
  const SyncFailureRecord({
    required this.count,
    required this.lastError,
    this.updatedAt,
  });

  /// 连续失败次数。
  final int count;

  /// 最近一次失败原因（展示用）。
  final String lastError;

  /// 失败时该文件的远端 `updated_at`（隔离后推进游标用）。
  final String? updatedAt;

  @override
  bool operator ==(Object other) =>
      other is SyncFailureRecord &&
      other.count == count &&
      other.lastError == lastError &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(count, lastError, updatedAt);

  @override
  String toString() =>
      'SyncFailureRecord(count: $count, lastError: $lastError)';
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
