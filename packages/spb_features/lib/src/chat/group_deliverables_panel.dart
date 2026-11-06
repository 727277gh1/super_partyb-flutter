import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_ui/spb_ui.dart';

/// 加载当前 group 的交付物清单（UFS `/api/files?path_prefix=…` 的分页汇总）。
///
/// 由 app 装配层实现：它持有 Riverpod provider、拼接 `groupId`、做分页。
/// 页面本身**不**依赖 `spb_api`——与 `AgentFileCard` / `ConversationPage`
/// 同一约定（注入意图，不碰 HTTP），故可在无头环境用内存桩完整验证。
typedef LoadGroupDeliverables = Future<List<UfsFileEntry>> Function();

/// 下载单个交付物，返回**用户可见的落地路径**（空串表示无路径可报）。
///
/// 与小程序工作台 `SaveArtifactBytes` 同一形态：页面负责展示与防重复点，
/// 落盘由 app 层决定（桌面端固定目录、移动端沙箱、或弹保存框）。
///
/// ## 落地布局：按 groupId 分目录
///
/// 实现方**应当**把文件写到 `…/downloads/deliverables/{groupId}/<group 内相对路径>`，
/// 而不是平铺成一个目录。理由：
///
/// 1. 不同 group 各有自己的 `README.md` / `reports/a.md`，平铺会**互相覆盖**
///    （用户看到的是「下载完内容变了」）；
/// 2. 平铺后用户根本分不清文件属于哪个对话——而下载的用途就是去文件管理器里
///    找它。
///
/// 传入的是整个 [UfsFileEntry]，它同时带 `path`（UFS 物化路径）与
/// `parentId`，故实现方有足够信息推导出 group 内相对路径；本 typedef 不额外
/// 传 groupId，避免「同一个值两个来源」（面板的 `groupId` 与文件的 `path`
/// 不一致时以谁为准无解）。
typedef DownloadDeliverable = Future<String> Function(UfsFileEntry file);

/// 用系统默认程序打开已下载到本地的文件。返回是否成功发起。
typedef OpenLocalDeliverable = Future<bool> Function(String path);

/// 在系统文件管理器中定位已下载文件。返回是否成功发起。
typedef RevealLocalDeliverable = Future<bool> Function(String path);

/// 查询某个交付物**在同步目录里的本地绝对路径**（未同步返回 null）。
///
/// 与 [DownloadDeliverable] 的区别是「这份文件从哪来」：
/// - [DownloadDeliverable]：用户点「下载」，把远端内容拉到应用目录；
/// - 本回调：**只查询**，回答「交付物同步是否已经把这文件放到用户选的目录里了」。
///
/// 由 app 装配层实现（它持有同步状态库与同步目录），页面本身不碰存储。
typedef ResolveLocalDeliverable = String? Function(UfsFileEntry file);

/// 当前 group 的交付物侧边栏。
///
/// ## 它解决什么（与既有组件的边界）
///
/// - 时间线里的 [AgentFileCard] 是 **事件日志**：「agent 刚在第 N 轮产出了
///   spec.md」。带时间上下文，在对话流里可追溯。
/// - 本面板是 **当前权威快照**：「这个 group 现在 workspace 里有哪些文件」，
///   按目录树组织，可浏览、可批量操作。
/// - 两者的数据源不同：内联卡来自 SSE `agent.file.*` 事件归约（增量投影），
///   本面板来自 UFS `/api/files`（全量清单）。**保留两者**——删内联卡会丢失
///   「什么时候产生的」这条维度（与 webapp `WorkbenchGroupDocsPanel` 与时间线
///   文件卡并存的理由一致）。
///
/// ## 为什么页面不碰文件系统 / 网络
///
/// `spb_features` 已依赖 `spb_api`，但把「这一页的请求装配」放进页面会让
/// widget test 必须配 HTTP mock（见 `agent_file_card_test.dart` 的取舍记录）。
/// 故全部靠注入：[loadFiles] 取数、[onDownload] / [onOpen] / [onReveal] 发动作，
/// 页面只负责渲染与防重复点。
///
/// ## 「打开 / 定位」的两条本地路径来源
///
/// 远端文件没有本地路径，无法交给系统默认程序或文件管理器。本面板按**优先级**
/// 取两者之一：
///
/// 1. [resolveLocalPath]（交付物**同步**索引）：**已同步则直接打开**——用户若
///    已把该 group 同步到本地目录，文件早就在磁盘上了，不必再下载一次；
/// 2. [onDownload] 的落地路径（用户在本面板里点过「下载」）。
///
/// 两者都没有时「打开 / 定位」禁用——并在菜单项上体现为 `enabled: false`，
/// 而不是点了没反应。
///
/// （「已同步则直接打开」曾是待做项，现已打通：同步索引 → 本地相对路径由
/// `spb_domain` 的 `resolveLocalDeliverablePath` 计算，app 层把它接成
/// [resolveLocalPath]。）
///
/// ## 为什么同步索引优先于下载路径
///
/// 同步目录里的那份是**用户自己选的目录**，也是他在文件管理器里能找到的地方；
/// 面板的下载目录是应用支持目录下的隐藏位置，用户不容易找到。同一个文件两边
/// 都有时，指向用户熟悉的那份更符合预期。
///
/// ## 为什么 [resolveLocalPath] 是同步回调
///
/// 它在 `build` 期间对每个可见文件调用。实现方必须读**已加载好的**状态快照
/// （由 app 层用 provider 预先加载），而不是在这里做磁盘/数据库查询——否则
/// 列表滚动会触发大量同步 IO。
///
/// ## 刷新模型
///
/// 不轮询、不自己建 SSE（实时流由 app 层已有的 `ChatStreamController` 维护）。
/// 本面板只在两类时机重新拉取：
/// 1. [groupId] 变化（切对话）；
/// 2. [reloadToken] 变化（app 在收到新的 `agent.file.*` 事件后 bump 令牌）；
/// 3. 用户点头部刷新按钮。
///
/// 为什么不比较 [loadFiles] 的函数身份：父层每次 `build` 都会创建新闭包，
/// 按身份判等会**每次 rebuild 都重拉**。显式令牌把「该刷新了」这个意图
/// 从「闭包换了」里解耦出来。
class GroupDeliverablesPanel extends StatefulWidget {
  const GroupDeliverablesPanel({
    super.key,
    required this.groupId,
    required this.loadFiles,
    this.onDownload,
    this.onOpen,
    this.onReveal,
    this.resolveLocalPath,
    this.reloadToken,
    this.title = '交付物',
    this.emptyHint = '这个对话还没有交付物',
  });

  /// 当前 group id。变化时清空本地路径缓存并重新加载。
  final String groupId;

  final LoadGroupDeliverables loadFiles;

  /// 下载回调。为 null 时下载项不出现（侧边栏退化为只读浏览）。
  final DownloadDeliverable? onDownload;

  final OpenLocalDeliverable? onOpen;
  final RevealLocalDeliverable? onReveal;

  /// 交付物同步索引查询（见类文档「两条本地路径来源」）。null = 不做同步查询
  /// （此时「打开 / 定位」仍只在手动下载后可用）。
  final ResolveLocalDeliverable? resolveLocalPath;

  /// 刷新令牌：变化时强制重新拉取。
  ///
  /// 传一个随刷新时机变化的值即可（如自增 int）。详见类文档「刷新模型」。
  final Object? reloadToken;

  final String title;

  final String emptyHint;

  @override
  State<GroupDeliverablesPanel> createState() => _GroupDeliverablesPanelState();
}

class _GroupDeliverablesPanelState extends State<GroupDeliverablesPanel> {
  List<UfsFileEntry> _entries = const [];
  List<ArtifactNode> _tree = const [];
  bool _loading = true;
  String? _error;

  /// 正在下载的文件 id（防重复点 + 展示 spinner）。
  final _downloading = <String>{};

  /// 已下载文件的本地落地路径：`ufs file id → 本地路径`。
  ///
  /// 只存**本面板内下载**的结果。同步索引那份由 [GroupDeliverablesPanel.resolveLocalPath]
  /// 实时查询（不缓存：同步可能在本页打开期间推进，缓存会让「刚同步好的文件」
  /// 仍显示为不可打开）。
  final _localPaths = <String, String>{};

  /// 该文件可用的本地路径（同步索引优先，其次本面板的下载记录）。
  String? _localPathOf(ArtifactFileNode node) {
    final fromSync = widget.resolveLocalPath?.call(node.file);
    if (fromSync != null && fromSync.isNotEmpty) return fromSync;
    return _localPaths[node.file.id];
  }

  /// 内存账本登记令牌（[MemoryLedger.register] 的返回值）。
  ///
  /// 交付物清单是「按 group 全量拉取」的（生产单 group 可达 5666 个文件），
  /// 故它必须出现在诊断报告的内存分解里——否则「打开交付物面板后 RSS 跳升」
  /// 只能靠猜。读数闭包捕获本 State，**必须**在 [dispose] 里注销。
  int? _ledgerToken;

  /// 是否至少有一个动作回调（决定行尾菜单是否渲染）。
  bool get _hasAnyAction =>
      widget.onDownload != null ||
      widget.onOpen != null ||
      widget.onReveal != null;

  int get _fileCount =>
      _entries.where((e) => !e.isDirectory && !e.isDeleted).length;

  @override
  void initState() {
    super.initState();
    _ledgerToken = MemoryLedger.register(
      name: 'deliverables.panel',
      label: '交付物面板清单',
      // 估算口径：清单条目 + 已构建的可见行（行缓存是懒的，折叠子树不进行）。
      // 字节数不估算（节点持有的是路径字符串与 UFS 元数据，逐项精确统计
      // 的收益不抵复杂度），报告里只体现「多少项」。
      read: () =>
          MemoryGauge(count: _entries.length + _rowsCache.length, bytes: 0),
      warnCount: 2000,
    );
    _load();
  }

  @override
  void dispose() {
    final token = _ledgerToken;
    if (token != null) MemoryLedger.unregister(token);
    super.dispose();
  }

  @override
  void didUpdateWidget(GroupDeliverablesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      _localPaths.clear();
      // 换对话后旧展开状态不再适用（目录名可能相同但语义已不同），
      // 重置到「顶层展开」默认态——与切换对话后重新加载的清单一致。
      _userExpansion.clear();
      _load();
    } else if (oldWidget.reloadToken != widget.reloadToken) {
      // 保留已下载路径与展开状态（同一对话内刷新，下载过的文件仍在本地、
      // 用户正在看的目录不应被折叠回去），只重拉清单。切对话时上面已清。
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.loadFiles();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _tree = buildArtifactTree(entries, groupId: widget.groupId);
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      SpbLog.warn('加载交付物清单失败', {'group': widget.groupId, 'error': '$e'});
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _download(ArtifactFileNode node) async {
    final cb = widget.onDownload;
    if (cb == null) return;
    final id = node.file.id;
    if (_downloading.contains(id)) return;
    setState(() => _downloading.add(id));
    try {
      final path = await cb(node.file);
      if (!mounted) return;
      if (path.isNotEmpty) {
        setState(() => _localPaths[id] = path);
        // 带上「定位」动作：落盘目录现在是 `{groupId}/<相对路径>`（见
        // `deliverableDownloadRelPath`），比平铺深了一层，用户手动翻到的
        // 成本更高。有回调时给一个直接入口，把「下载完还得自己找」补上。
        //
        // 提示文案保留完整路径：没接回调（移动端）或定位失败时，它是
        // 用户唯一的线索。
        _showMessage(
          '已下载到 $path',
          action: widget.onReveal == null
              ? null
              : SnackBarAction(label: '定位', onPressed: () => _reveal(node)),
        );
      } else {
        _showMessage('已下载');
      }
    } on Object catch (e) {
      if (!mounted) return;
      _showMessage('下载失败：$e');
    } finally {
      if (mounted) setState(() => _downloading.remove(id));
    }
  }

  Future<void> _open(ArtifactFileNode node) async {
    final path = _localPathOf(node);
    final cb = widget.onOpen;
    if (path == null || cb == null) return;
    try {
      final ok = await cb(path);
      if (!mounted) return;
      if (!ok) _showMessage('无法打开文件');
    } on Object catch (e) {
      if (mounted) _showMessage('打开失败：$e');
    }
  }

  Future<void> _reveal(ArtifactFileNode node) async {
    final path = _localPathOf(node);
    final cb = widget.onReveal;
    if (path == null || cb == null) return;
    try {
      final ok = await cb(path);
      if (!mounted) return;
      if (!ok) _showMessage('无法定位文件');
    } on Object catch (e) {
      if (mounted) _showMessage('定位失败：$e');
    }
  }

  void _showMessage(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      // 侧边栏视觉边界：左侧分隔线 + 与主区一致的背景。
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const Divider(height: 1),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.md,
        vertical: SpbSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_copy_outlined,
            size: SpbSpacing.lg,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            child: Text(
              widget.title,
              style: theme.textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_fileCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: SpbSpacing.xs),
              child: Text(
                '$_fileCount 个文件',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          // 刷新：加载中禁用，避免叠请求。
          IconButton(
            key: const ValueKey('deliverables-refresh'),
            icon: const Icon(Icons.refresh, size: SpbSpacing.lg),
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    // 首次加载（尚无数据）才显示整屏 spinner；后续刷新保留旧内容，避免闪白。
    if (_loading && _entries.isEmpty) {
      return const Center(
        key: ValueKey('deliverables-loading'),
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return Padding(
        key: const ValueKey('deliverables-error'),
        padding: SpbSpacing.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ErrorBanner(
              key: const ValueKey('deliverables-error-banner'),
              message: _error!,
            ),
            const SizedBox(height: SpbSpacing.md),
            FilledButton.tonal(
              key: const ValueKey('deliverables-retry'),
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_tree.isEmpty) {
      return Center(
        key: const ValueKey('deliverables-empty'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Text(
            widget.emptyHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      key: const ValueKey('deliverables-tree'),
      padding: const EdgeInsets.symmetric(vertical: SpbSpacing.xs),
      itemCount: _rows.length,
      itemBuilder: (context, index) =>
          _buildNode(_rows[index].node, _rows[index].depth),
    );
  }

  Widget _buildNode(ArtifactNode node, int depth) {
    return switch (node) {
      ArtifactDirectoryNode() => _buildDirectory(node, depth),
      ArtifactFileNode() => _buildFile(node, depth),
    };
  }

  /// 展开状态下**可见**的节点列表（build 期派生，缓存到字段）。
  ///
  /// ## 为什么不用 `ListView(children: _tree.map(...))`（docs/memory-audit.md G7）
  ///
  /// `ListView(children:)` 走 `SliverChildListDelegate`——**build 阶段就把
  /// 全部子 widget 构造出来**。5666 文件的全量同步场景，打开「交付物」tab 的
  /// 一帧要构造 5666 个节点 widget（目录节点还是 `ExpansionTile`：StatefulWidget
  /// + controller 装配），其中绝大部分滚出视口后立即丢弃——纯浪费。
  /// `ListView.builder` 只构建可见行（± cacheExtent）。
  ///
  /// ## 展开状态怎么表达
  ///
  /// `ExpansionTile` 自持展开/折叠状态（`PageStorageKey` 跨切换保留），但
  /// **折叠的子节点不能进 rows**——否则折叠只是视觉隐藏、行仍被构建。
  /// `ExpansionTile` 无法反过来驱动本列表，故展开状态由本页自持
  /// （`_userExpansion`），目录行点击时翻转，派生 `_rows` 时只递归展开中的
  /// 目录。顶层目录默认展开（与原 `initiallyExpanded: depth == 0` 一致）。
  ///
  /// 缓存判据与时间线的 `_displayRows` 同型：`_tree` 未变（`identical`）时
  /// 不重算。展开状态变化（点击目录）才会触发重算——那是用户主动交互，
  /// 一次 O(n) 摊销可接受。
  List<({ArtifactNode node, int depth})> get _rows {
    if (identical(_rowsSource, _tree) && _rowsSourceRev == _rowsRev) {
      return _rowsCache;
    }
    final rows = <({ArtifactNode node, int depth})>[];
    void walk(List<ArtifactNode> nodes, int depth) {
      for (final node in nodes) {
        rows.add((node: node, depth: depth));
        final dir = node;
        if (dir is ArtifactDirectoryNode && _isExpanded(dir, depth)) {
          walk(dir.children, depth + 1);
        }
      }
    }

    walk(_tree, 0);
    _rowsSource = _tree;
    _rowsSourceRev = _rowsRev;
    _rowsCache = rows;
    return rows;
  }

  List<({ArtifactNode node, int depth})> _rowsCache = const [];
  List<ArtifactNode>? _rowsSource;
  int _rowsSourceRev = -1;

  /// 展开状态翻转时递增（见 [_toggleDirectory]）。同一棵树下行的集合会
  /// 随之变化，只比 `_tree` 的 identity 不够。
  int _rowsRev = 0;

  /// 展开状态：目录相对路径 → 用户设置的展开与否。
  ///
  /// 只存**用户点过**的目录；没点过的按层级取默认值（顶层展开、深层折叠，
  /// 与原 `initiallyExpanded: depth == 0` 一致）。故本表的大小与「用户
  /// 交互过多少个目录」成正比，不随文件总数增长。
  ///
  /// 为什么不用 `ExpansionTile` 自持状态：见 [_rows] 的注释——折叠的子节点
  /// 必须**不进 rows**，否则折叠只是视觉隐藏、行仍被构建，`ListView.builder`
  /// 就白用了。`ExpansionTile` 无法反向驱动本列表。
  final Map<String, bool> _userExpansion = <String, bool>{};

  bool _isExpanded(ArtifactDirectoryNode dir, int depth) =>
      _userExpansion[dir.relativePath] ?? (depth == 0);

  void _toggleDirectory(ArtifactDirectoryNode dir, int depth) {
    setState(() {
      _userExpansion[dir.relativePath] = !_isExpanded(dir, depth);
      // 可见行集合变了，必须让 [_rows] 的缓存失效（展开状态是行的输入之一，
      // 只比对 `_tree` 的 identity 会拿到翻转前的旧行——那样点击目录没反应）。
      _rowsRev++;
    });
  }

  Widget _buildDirectory(ArtifactDirectoryNode dir, int depth) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final expanded = _isExpanded(dir, depth);
    return ListTile(
      key: ValueKey<String>('artifact-dir-${dir.relativePath}'),
      dense: true,
      minTileHeight: 0,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.only(
        left: SpbSpacing.sm + depth * SpbSpacing.lg,
        right: SpbSpacing.sm,
      ),
      onTap: () => _toggleDirectory(dir, depth),
      leading: Icon(
        Icons.folder_outlined,
        size: SpbSpacing.lg,
        color: scheme.primary,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              dir.name,
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (dir.fileCount > 0)
            Text(
              '${dir.fileCount}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      // 原 ExpansionTile 自带旋转箭头，换成自持状态后由本行提供（语义同等：
      // 朝下 = 折叠、朝上 = 展开）。
      trailing: AnimatedRotation(
        turns: expanded ? 0.5 : 0,
        duration: const Duration(milliseconds: 150),
        child: Icon(
          Icons.expand_more,
          size: SpbSpacing.md,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildFile(ArtifactFileNode node, int depth) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final localPath = _localPathOf(node);
    final busy = _downloading.contains(node.file.id);
    final canOpen = localPath != null && widget.onOpen != null;
    final canReveal = localPath != null && widget.onReveal != null;

    return ListTile(
      key: ValueKey<String>('artifact-file-${node.relativePath}'),
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.only(
        left: SpbSpacing.md + depth * SpbSpacing.lg,
        right: SpbSpacing.xs,
      ),
      leading: Icon(
        _fileIcon(node.file),
        size: SpbSpacing.lg,
        color: scheme.onSurfaceVariant,
      ),
      title: Text(
        node.name,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: theme.textTheme.bodyMedium,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (node.file.size > 0)
            Text(
              humanBytes(node.file.size),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          if (_hasAnyAction) ...[
            const SizedBox(width: SpbSpacing.xs),
            _fileMenu(node, busy: busy, canOpen: canOpen, canReveal: canReveal),
          ],
        ],
      ),
      // 单击：若已下载且提供打开回调，则直接打开（最常见的二级动作）。
      onTap: canOpen ? () => _open(node) : null,
    );
  }

  Widget _fileMenu(
    ArtifactFileNode node, {
    required bool busy,
    required bool canOpen,
    required bool canReveal,
  }) {
    return PopupMenuButton<String>(
      key: ValueKey<String>('deliverable-menu-${node.relativePath}'),
      enabled: !busy,
      icon: busy
          ? const SizedBox(
              width: SpbSpacing.lg,
              height: SpbSpacing.lg,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.more_vert, size: SpbSpacing.lg),
      tooltip: '操作',
      padding: EdgeInsets.zero,
      onSelected: (v) {
        switch (v) {
          case 'download':
            _download(node);
          case 'open':
            _open(node);
          case 'reveal':
            _reveal(node);
        }
      },
      itemBuilder: (context) => [
        if (widget.onDownload != null)
          const PopupMenuItem<String>(value: 'download', child: Text('下载')),
        if (widget.onOpen != null)
          PopupMenuItem<String>(
            value: 'open',
            enabled: canOpen,
            child: const Text('用默认程序打开'),
          ),
        if (widget.onReveal != null)
          PopupMenuItem<String>(
            value: 'reveal',
            enabled: canReveal,
            child: const Text('在文件管理器中定位'),
          ),
      ],
    );
  }

  /// 按 MIME 选图标。与 `AgentFileCard` 同一视觉语言，但更细分类别
  /// （交付物面板以文件浏览为主，类型区分有助于扫读）。
  IconData _fileIcon(UfsFileEntry f) {
    final mt = (f.mimeType ?? '').toLowerCase();
    if (mt.startsWith('image/')) return Icons.image_outlined;
    if (mt.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mt.startsWith('video/')) return Icons.movie_outlined;
    if (mt.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (mt.startsWith('text/') ||
        mt.contains('markdown') ||
        mt.contains('json') ||
        mt.contains('xml') ||
        mt.contains('yaml')) {
      return Icons.description_outlined;
    }
    if (mt.contains('zip') || mt.contains('tar') || mt.contains('gzip')) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}
