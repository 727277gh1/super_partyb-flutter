import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'deliverable_sync.dart';
import 'group_sync_probe.dart';
import 'sync_cursor.dart';
import 'sync_path.dart';
import 'sync_state.dart';

/// 交付物同步用例：把「列表 → 计划 → 执行 → 存状态」串起来。
///
/// ## 为什么需要它（而不是让 UI 直接调 [SyncEngine]）
///
/// [SyncEngine] 只处理**一页**远端条目。真实的 UFS 列表是**分页**的
/// （`page_size` 上限 100，见 `internal/handler/files.go`），而同步状态是
/// **单游标**的——这意味着分页拉取必须满足两条约束，否则会静默漏文件：
///
/// 1. **必须拉完所有页再执行**，不能「拉一页执行一页」：后者会在中途推进游标，
///    而后续页里的条目 `updated_at` 可能早于新游标，于是下一轮增量再也拉不到
///    它们（永久漏更新）；
/// 2. **游标只能由成功的下载推进**（[SyncEngine] 已保证），故分页本身不能
///    推进游标。
///
/// 这两条是「编排」层面的正确性，不属于纯计划逻辑，也不该散在 UI 里。
///
/// ## 依赖都是接口
///
/// [UfsApi] 是具体类（它只做 HTTP，无策略），[SyncStateStore] / [FileSink] /
/// [FileDownloader] 都是 domain 定义的接口。故本用例可以在无网络、无磁盘的
/// 环境下完整单测（注入内存桩）。
class DeliverableSyncUseCase {
  const DeliverableSyncUseCase({
    required this.ufs,
    required this.stateStore,
    required this.sink,
    required this.downloader,
    this.pageSize = 100,
    this.concurrency = SyncEngine.defaultConcurrency,
  });

  final UfsApi ufs;
  final SyncStateStore stateStore;
  final FileSink sink;
  final FileDownloader downloader;

  /// 每页条数。服务端上限 100（超过会被拒或截断），故取上限以减少往返。
  final int pageSize;

  /// 落盘阶段的并发上限（在途 IO 数）。默认见 [SyncEngine.defaultConcurrency]。
  ///
  /// 暴露到编排层是为了让「限流严格的服务端」能把它调小，而不用改 domain 代码。
  /// `1` = 串行（旧行为）。
  final int concurrency;

  /// 执行一轮同步。
  ///
  /// [stateKey] 由 `syncStateKeyFor(scope)` 得出（单 group 用 groupId，
  /// workspace 类范围共用 `__workspace__`）。
  ///
  /// ## 首次全量 vs 增量
  ///
  /// 无已保存游标时**不加** `updated_since`（全量）。若首次就发增量请求，
  /// 服务端只返回近期变化，本地会漏掉全部历史交付物，而用户以为同步完成了。
  ///
  /// ## 为什么始终带 `include_deleted=true`
  ///
  /// 增量清单**不能**用「条目缺席」推断删除（缺席只说明本轮无变化），
  /// 删除只能靠条目自带的 `deleted_at`。故必须显式要求服务端返回软删除条目。
  Future<SyncReport> run({
    required SyncScope scope,
    required SyncFilterConfig filter,
    int? sinceDays,
    int? nowUnixOverride,
  }) async {
    final stateKey = syncStateKeyFor(scope);
    final state = await stateStore.load(stateKey);

    // 时间下限：取「已保存游标」与「since_days 推出的下限」中**更晚**的一个。
    // 见 sync_cursor.dart 的 effectiveCursor（纯函数，已有单测）。
    //
    // [nowUnixOverride] 仅供测试注入固定时刻，生产不传。
    //
    // ## 定向同步的「已保存游标」是**本 group 的水位**，不是共享游标
    //
    // 共享游标是「整个 workspace 已同步到哪」。它可能远晚于本 group 的进度
    // （用户刚把本 group 勾进范围、或上一轮全范围同步时本 group 被过滤），
    // 拿它当下限会**把本 group 真正缺失的旧文件过滤掉**。
    //
    // 那不是理论风险：判定（`checkGroupSyncNeedProvider`）用的下限是本 group
    // 水位，同步用的若是共享游标，两者就不一致——提示条说「有 3 个未同步」，
    // 用户点下去却下载 0 个，且报告显示成功。
    //
    // 用本 group 水位当下限同时是**更宽**的（水位 ≤ 共享游标），故不会多漏
    // 任何文件；重复列出的那些靠 etag 命中跳过，代价只是一页元数据。
    final saved = switch (scope) {
      SyncSingleGroupScope(:final groupId) => groupSyncWatermark(
        state: state,
        stateKey: stateKey,
        groupId: groupId,
      ).latestUpdatedAt,
      _ => state.cursor,
    };
    final cursor = effectiveCursor(
      saved: saved,
      sinceDays: sinceDays,
      nowUnix: nowUnixOverride ?? nowUnix(),
    );

    final remote = await _listAll(
      pathPrefix: _pathPrefixFor(scope),
      updatedSince: cursor,
    );

    final engine = SyncEngine(
      downloader: downloader,
      sink: sink,
      concurrency: concurrency,
    );
    final result = await engine.run(
      remote: remote,
      state: state,
      scope: scope,
      filter: filter,
    );

    // 状态落盘失败不该让整轮同步算失败（文件已正确落盘，状态可下轮重建），
    // 但必须让调用方知道——否则游标不推进会反复全量拉取。
    //
    // 故这里把它转成 [StorageError] 抛出（而不是静默吞掉）。代价是「本轮
    // 报告丢失」，但那比「用户以为同步好了、其实每轮都在全量重拉」更可诊断。
    await stateStore.save(stateKey, result.state);
    return result.report;
  }

  /// 拉完所有页。
  ///
  /// 用 `total` 判断是否还有下一页，而不是「本页条数 == pageSize」：
  /// 后者在「总数恰好是 pageSize 整数倍」时会多发一次空请求，且若服务端
  /// 因过滤少返回几条就会**提前停止**而漏文件。
  Future<List<UfsFileEntry>> _listAll({
    required String pathPrefix,
    String? updatedSince,
  }) async {
    final all = <UfsFileEntry>[];
    var page = 1;

    while (true) {
      final result = await ufs.listFiles(
        pathPrefix: pathPrefix,
        updatedSince: updatedSince,
        // 必须为 true：删除只能靠 deleted_at 感知（见 run 的说明）。
        includeDeleted: true,
        page: page,
        pageSize: pageSize,
      );
      all.addAll(result.items);

      // 防御：服务端返回空页但 total 声称还有更多 → 继续会死循环。
      // 以「本页为空」作为终止条件，避免把服务端 bug 变成客户端挂死。
      if (result.items.isEmpty) break;
      if (!result.hasMore(page: page, pageSize: pageSize)) break;

      page++;
      if (page > _maxPages) {
        // 用 [ParseError] 而非 [SpbError]：后者是 sealed（隐式 abstract），
        // 不能在库外实例化。语义上这确实是「服务端响应不符合契约」。
        throw const ParseError('交付物列表分页超过 $_maxPages 页，已中止（疑似服务端 total 异常）');
      }
    }

    return all;
  }

  /// 分页上限（安全阀）。
  ///
  /// 生产全量约 5666 条 / 100 = 57 页，200 页留足余量。设上限是为了让
  /// 「服务端 total 永远大于实际返回」这类 bug 变成明确报错而不是无限循环。
  static const int _maxPages = 200;

  /// 远端路径前缀。
  ///
  /// ## 定向同步（[SyncSingleGroupScope]）收窄到该 group 的子树
  ///
  /// 直接 `path_prefix=/workspace/groups/{gid}`（尾斜杠由服务端
  /// `NormalizePath` 补齐，故 `g1` 不会误匹配 `g10`）。这同时带来两个好处：
  /// 少拉无关元数据，且「只同步这个对话」在请求层面就是真的定向。
  ///
  /// ## workspace 类范围仍用全 workspace 前缀
  ///
  /// `SyncWorkspaceScope` / `SyncGroupsScope` 共用 `__workspace__` 状态键与
  /// 同一套游标语义，且后者的过滤在 [SyncScope.relativePath] 里做（未选中的
  /// group 记为 `invalidPath` 跳过）。若为「勾选若干」也收窄成多个前缀，
  /// 就得分多次列举再合并——而**多次列举 + 单游标**正是「漏文件」的经典
  /// 来源（各页推游标的子集上界不一致）。保持一次列举，让过滤留在本地。
  ///
  /// [SyncGroupScope] 同样收窄（它的语义本就是「只要这一个 group」）。
  String _pathPrefixFor(SyncScope scope) => switch (scope) {
    SyncGroupScope(:final groupId) => '$workspaceGroupsPrefix$groupId',
    SyncSingleGroupScope(:final groupId) => '$workspaceGroupsPrefix$groupId',
    SyncWorkspaceScope() => workspaceGroupsPrefix,
    SyncGroupsScope() => workspaceGroupsPrefix,
  };
}

/// 把 [UfsApi] 适配成 [FileDownloader]。
///
/// ## 为什么在这里而不是 app 层
///
/// 这是纯粹的**类型适配**（`UfsDownload` → `SyncDownloadResult`），没有任何
/// 平台或环境依赖。放在 domain 里让两个 app 共用，避免各写一份（那两份很容易
/// 在「304 怎么表达」上产生分歧）。
///
/// ## 304 的映射是这里唯一的语义
///
/// `UfsDownload.notModified` 为 true 时必须映射成
/// `SyncDownloadResult.notModified()` 而**不是**「0 字节的内容」——后者会让
/// 引擎把本地已有文件覆盖成空文件。
class UfsFileDownloader implements FileDownloader {
  const UfsFileDownloader(this.ufs);

  final UfsApi ufs;

  @override
  Future<SyncDownloadResult> download(
    String fileId, {
    String? ifNoneMatch,
  }) async {
    final result = await ufs.download(fileId, ifNoneMatch: ifNoneMatch);
    if (result.notModified) return const SyncDownloadResult.notModified();
    return SyncDownloadResult.downloaded(result.bytes ?? const <int>[]);
  }
}
