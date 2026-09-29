import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';

part 'database.g.dart';

/// 同步游标：每个状态键一行。
///
/// 单独一张表（而不是把游标塞进文件记录表）是因为它们的**基数不同**：
/// 游标是「每个状态键一个」，文件记录是「每个状态键 × 每个文件一个」。
/// 混在一起就得靠「rel_path 为空的特殊行」表示游标，读写都要特判。
@DataClassName('SyncCursorRow')
class SyncCursors extends Table {
  /// 状态键（group_id 或 [workspaceStateKey]）。
  TextColumn get stateKey => text()();

  /// 上次成功同步的服务端时间点（RFC3339）。null = 从未成功同步（下轮全量）。
  TextColumn get cursor => text().nullable()();

  @override
  Set<Column> get primaryKey => {stateKey};
}

/// 已同步文件的 etag 记录。
///
/// 复合主键 `(state_key, rel_path)`：同一路径在一个状态键下只能有一条记录，
/// 重复写入必须是**覆盖**（upsert），否则 `is_unchanged` 会读到陈旧 etag
/// 而跳过本应执行的下载。
@DataClassName('SyncedFileRow')
class SyncedFiles extends Table {
  TextColumn get stateKey => text()();

  /// group 内相对路径（如 `grp_1/reports/a.md`）。
  TextColumn get relPath => text()();

  /// 服务端内容指纹。null 表示服务端未返回，退化为按 [size] 比对。
  TextColumn get etag => text().nullable()();

  /// 同步时的字节数（etag 缺失时的兜底依据）。
  IntColumn get size => integer()();

  /// 服务端 `updated_at` 原样保留，仅用于诊断展示。
  TextColumn get updatedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {stateKey, relPath};
}

/// 同步目录绑定：单行表（`id` 恒为 1）。
///
/// ## 为什么需要它
///
/// 状态描述的是「某个本地目录里已有什么」，**绑定在具体目录上**。用户换目录
/// 时必须整体清空状态，否则会出现「同步显示成功，但新目录是空的」：
///
/// - 保留游标 → 增量清单只返回 `updated_at >= 游标` 的文件，新目录几乎什么都
///   拿不到；
/// - 保留 etag → 少数恰好出现在清单里的文件被判为「未变更」而跳过写入，
///   但新目录里根本没有这个文件。
///
/// 把「当前绑定的是哪个目录」和状态存在**同一个数据库**里，是为了让「换目录
/// → 清状态」这一步不需要跨存储协调（跨存储会出现「目录已改、状态没清」的
/// 中间态，而那正是上面那个 bug）。
@DataClassName('SyncBindingRow')
class SyncBindings extends Table {
  IntColumn get id => integer()();

  /// 当前绑定的同步目录绝对路径。null = 尚未选过目录。
  TextColumn get localRoot => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 键值偏好（同步开关、上次落点等）。
///
/// 值统一存文本：调用方按需解析（`bool`/`int`/`json`）。用 `TEXT` 而不是
/// 多态列，是因为 SQLite 的动态类型会让「同一个键先后存了 bool 与 int」
/// 这种 bug 静默通过。
@DataClassName('PreferenceRow')
class Preferences extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 本地持久化数据库（同步状态 + 偏好）。
///
/// ## 为什么用 drift 而不是继续写 JSON 文件
///
/// 原 Tauri 端用「每个 group 一个 JSON 文件」（`sync-state/{group_id}.json`）。
/// 迁到 SQLite 的理由是**原子性与并发**：
///
/// - JSON 方案每次改动都要重写整个文件，同步过程中崩溃会留下半截 JSON；
///   drift 的单条 upsert 是事务性的；
/// - 多窗口（桌面端主窗 + 设置窗）可能同时读写，文件方案需要自己加锁；
/// - 清理/统计类查询（「已同步 N 个 group，共 X 字节」）用 SQL 表达更直接。
///
/// ⚠️ 但**语义必须保持一致**：状态键的选择（[workspaceStateKey]）、
/// 「失败项不写状态」、「换目录才重置」这几条都不能因为换了存储而改变。
@DriftDatabase(tables: [SyncCursors, SyncedFiles, SyncBindings, Preferences])
class AppDatabase extends _$AppDatabase {
  /// 用给定的执行器构造（生产传文件、测试传 `NativeDatabase.memory()`）。
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    // 版本 1 暂无迁移。将来加字段时在此按 from→to 分支处理，
    // **不要**用 `m.createAll()` 兜底：那会丢用户已有的同步状态。
  );
}

/// 在给定文件上打开数据库（懒开 + 后台 isolate 执行查询）。
///
/// ## 为什么提供这个工厂（而不是让各 app 自己拼）
///
/// 打开数据库需要 `NativeDatabase` / `LazyDatabase`（来自 `drift`）以及
/// `createInBackground`（来自 `drift/native`）。若各 app 自己拼，它们就得把
/// `drift` 声明成直接依赖——那会让「drift 的版本与用法」散落在多个 pubspec 里，
/// 升级时容易漏改一处。收敛到这里后，app 只需 `AppDatabase.openAt(file)`。
///
/// ## 为什么懒开 + 后台 isolate
///
/// 开库是 IO（建目录 + 打开文件）。`LazyDatabase` 把这一步推迟到**首次真正
/// 查询**时，构造 `AppDatabase` 不会阻塞 UI 线程；`createInBackground` 让查询
/// 在后台 isolate 里执行，避免同步大批量写入卡住界面。
///
/// 调用方负责关闭（`db.close()`）。
AppDatabase openAppDatabaseAt(File file) {
  final dir = file.parent;
  if (!dir.existsSync()) {
    try {
      dir.createSync(recursive: true);
    } on FileSystemException catch (e) {
      // 建目录失败（权限/只读文件系统）：不在这里抛——让它在下游以
      // 「打开失败」的形式暴露，错误信息更贴近实际根因。
      SpbLog.warn('创建数据库目录失败', {
        'dir': dir.path,
        'error': e.toString(),
      });
    }
  }
  return AppDatabase(
    LazyDatabase(() async => NativeDatabase.createInBackground(file)),
  );
}

/// 在**异步解析出的**文件上打开数据库（懒开 + 后台 isolate）。
///
/// 与 [openAppDatabaseAt] 的区别只有一点：路径是异步拿到的。移动端必须这样
/// ——它的应用数据目录只能通过 `path_provider` 的平台通道获得（`getApplicationSupportDirectory()`
/// 是 async），而不像桌面端可以直接读 `XDG_DATA_HOME` / `$HOME`。
///
/// [resolve] 在**首次真正查询时**才被调用（`LazyDatabase` 的语义），
/// 因此构造 `AppDatabase` 不会触碰平台通道——这对 widget test 很重要：
/// 测试若 override 掉本 Provider 就不会触发 `MissingPluginException`。
AppDatabase openAppDatabaseLazy(Future<File> Function() resolve) {
  return AppDatabase(
    LazyDatabase(() async {
      final file = await resolve();
      final dir = file.parent;
      if (!dir.existsSync()) {
        try {
          dir.createSync(recursive: true);
        } on FileSystemException catch (e) {
          SpbLog.warn('创建数据库目录失败', {
            'dir': dir.path,
            'error': e.toString(),
          });
        }
      }
      return NativeDatabase.createInBackground(file);
    }),
  );
}

/// 把状态值类型（[SyncedFile]）与 drift 行类型互转。
extension SyncedFileRowMapper on SyncedFileRow {
  SyncedFile toDomain() =>
      SyncedFile(etag: etag, size: size, updatedAt: updatedAt);
}

/// 把 domain 值类型转成 drift 伴随对象。
extension SyncedFileMapper on SyncedFile {
  SyncedFilesCompanion toCompanion(String stateKey, String relPath) =>
      SyncedFilesCompanion.insert(
        stateKey: stateKey,
        relPath: relPath,
        etag: Value(etag),
        size: size,
        updatedAt: Value(updatedAt),
      );
}
