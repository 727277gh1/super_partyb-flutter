import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';
import 'package:spb_ui/spb_ui.dart';

/// 加载工作详情（`GET /chat/miniapp/works/:id`）。
typedef LoadWorkDetail = Future<MiniappWorkDetail> Function();

/// 加载工作事件（`GET /chat/miniapp/works/:id/events`）。
///
/// 返回的是 [MiniappWorkEvent]（数据库原始行）而**不是** `ChatEvent`——见该类文档。
typedef LoadWorkEvents = Future<List<MiniappWorkEvent>> Function();

/// 加载产物列表（`GET /chat/miniapp/works/:id/artifacts`）。
typedef LoadWorkArtifacts = Future<List<MiniappArtifact>> Function();

/// 下载产物字节（`GET .../artifacts/:aid/download`）。
typedef DownloadArtifact = Future<List<int>> Function(String artifactId);

/// 保存下载到的字节，返回**用户可见的落地路径**。
///
/// 由 app 装配层实现（两端均写入应用支持目录下的 `deliverables/miniapp/`）。
/// 页面不碰文件系统——否则 `spb_features` 会为这一个页面引入平台依赖，
/// 且 widget test 无法验证。
///
/// 之所以不弹系统保存对话框（桌面端本可做到）：取消路径在调用方没有承载位置
/// ——`WorkDetailPage._download` 拿到返回值后直接提示「已保存到 $path」，
/// 用户取消时会提示一句空路径。与桌面端 `downloadDeliverableProvider` 同一
/// 取舍（那里配「打开 / 定位」能力，这里只提示路径）。
typedef SaveArtifactBytes = Future<String> Function(
  String filename,
  List<int> bytes,
);

/// 发送消息（`POST /chat/miniapp/works/:id/messages`）。
///
/// 返回 [MiniappDispatchResult]；**调用方需检查 `hasError`**——服务端把派发
/// 失败嵌在 200/201 响应体里，不是错误码。
typedef SendWorkMessage = Future<MiniappDispatchResult> Function(String input);

/// 完成 / 停止工作（`POST .../complete` 与 `.../stop`）。
typedef CompleteWork = Future<MiniappWorkDetail> Function();

/// 停止工作。
typedef StopWork = Future<MiniappWorkDetail> Function();

/// 解决确认卡（`POST /chat/miniapp/confirmations/:id/resolve`）。
///
/// 404 表示「非本人 / 已处理 / 已过期」，服务端刻意统一成一个响应以避免
/// 存在性探针——调用方应把 404 当「这张卡不用再显示了」而非错误。
typedef ResolveMiniappConfirmation = Future<void> Function(
  String confirmationId,
  String action,
);

/// 上传文件到工作（`POST /chat/miniapp/works/:id/files`）。
///
/// ## 为什么参数是「文件名 + 字节」而不是 `DroppedFile`
///
/// `MiniappApi.uploadFile` 只接受字节（服务端 `c.FormFile("file")`），没有
/// 从磁盘流式读的余地。若把 `DroppedFile` 传下去，实现层仍要先 `readBytes()`，
/// 只是把同一件事推远一层。这里明确：**页面负责读取字节**（它有 busy 状态
/// 可以反馈），注入点只收结果。
///
/// ## 为什么返回 `void` 而不是上传后的 artifact
///
/// 上传成功后本页会 `_reload()`（与 `_send` 同一做法）：服务端会重新投影
/// 产物列表，而本地拼接的 artifact 可能与服务端的 `id` 口径不一致（事件
/// 投影的 id 可能是合成的 `"<group_id>:<relative_path>"`）。重新拉取才一致。
typedef UploadWorkFile = Future<void> Function({
  required String filename,
  required List<int> bytes,
});

/// 工作详情页（小程序工作台）。
///
/// ## 能力位由服务端下发，页面不自己推状态
///
/// `can_send_message` / `can_stop` / `can_complete` 是服务端按 group 状态 +
/// work 状态算好的。页面**直接读它们**决定按钮可用性——状态机在服务端，
/// 客户端复刻一份必然漂移（`resolveWorkStatus` 有 6 个分支）。
///
/// ## 实时更新复用 SSE，不用长连接推送端点
///
/// 服务端另有 `/ws` + `/ws-tickets`，本仓库禁止引入（AGENTS.md §6.1）。
/// 故本页是「加载 + 手动刷新」模型：初次进页拉一次 events，之后由上层
/// （app 的 SSE 接线）或用户下拉刷新触发重新加载。
///
/// ## 错误处理分两类
///
/// - **加载失败**（详情/事件/产物）：显示错误 + 重试，不清空已有内容；
/// - **动作失败**（发消息/完成/停止/确认/下载）：SnackBar 提示，页面状态不变。
///
/// 二者的区别是「页面还能不能看」：加载失败时页面没有内容可看，动作失败时
/// 内容仍在——把它整个换成错误页会让用户丢掉正在看的东西。
class WorkDetailPage extends StatefulWidget {
  const WorkDetailPage({
    super.key,
    required this.loadDetail,
    required this.loadEvents,
    required this.loadArtifacts,
    required this.downloadArtifact,
    required this.saveArtifact,
    required this.sendMessage,
    required this.complete,
    required this.stop,
    required this.resolveConfirmation,
    this.onUploadFile,
    this.title = '工作详情',
  });

  final LoadWorkDetail loadDetail;
  final LoadWorkEvents loadEvents;
  final LoadWorkArtifacts loadArtifacts;
  final DownloadArtifact downloadArtifact;
  final SaveArtifactBytes saveArtifact;
  final SendWorkMessage sendMessage;
  final CompleteWork complete;
  final StopWork stop;
  final ResolveMiniappConfirmation resolveConfirmation;

  /// 上传附件到本工作。为 null 时不展示上传按钮（只读用法）。
  ///
  /// 文件选择走 `spb_platform` 的 `pickFilesForOverlay()`（页面不直接依赖
  /// `file_selector` 插件，见分层规则）。
  final UploadWorkFile? onUploadFile;

  final String title;

  @override
  State<WorkDetailPage> createState() => _WorkDetailPageState();
}

class _WorkDetailPageState extends State<WorkDetailPage> {
  MiniappWorkDetail? _detail;
  List<MiniappWorkEvent> _events = const [];
  List<MiniappArtifact> _artifacts = const [];

  bool _loading = true;
  SpbError? _error;

  /// 正在执行的**动作**（发消息 / 完成 / 停止 / 确认 / 下载）。
  ///
  /// 与 [_loading] 分开：动作进行中不应让整页变成转圈（用户还在看内容），
  /// 只禁用触发它的那个控件。
  bool _acting = false;
  final _downloading = <String>{};

  /// 正在上传附件（与 [_acting] 分开：上传有自己的耗时与提示文案）。
  bool _uploading = false;

  /// 已解决的确认卡 id（本地标记，避免重复点击）。
  ///
  /// 不用「从列表移除」：服务端返回的详情里那张卡仍可能短暂存在（本地未重拉），
  /// 标记后置灰即可，语义也更清楚（「这张我已经处理过了」）。
  final _resolved = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 三个请求并发：它们互不依赖，串行会让首屏慢 2 倍。
      final results = await Future.wait([
        widget.loadDetail(),
        widget.loadEvents(),
        widget.loadArtifacts(),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as MiniappWorkDetail;
        _events = results[1] as List<MiniappWorkEvent>;
        _artifacts = results[2] as List<MiniappArtifact>;
        _loading = false;
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 只重拉详情（动作成功后用；事件/产物不会因动作立刻变化）。
  Future<void> _refreshDetail() async {
    try {
      final d = await widget.loadDetail();
      if (!mounted) return;
      setState(() => _detail = d);
    } on SpbError catch (e) {
      if (!mounted) return;
      _snack('刷新失败：${e.message}');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
      );
  }

  /// 包装动作：统一的 busy 标记 + 错误提示。
  Future<void> _runAction(Future<void> Function() action) async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await action();
    } on SpbError catch (e) {
      if (mounted) _snack(e.message);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _send(String input) => _runAction(() async {
    final result = await widget.sendMessage(input);
    if (!mounted) return;
    // ## 必须检查 hasError
    //
    // 服务端把派发失败嵌在响应体里（`{"dispatch":{"error":...}}`），HTTP 仍是
    // 201。不检查的话「发送失败」会被显示成成功，用户会一直等一个不存在的回答。
    if (result.hasError) {
      _snack('发送失败：${result.error}');
      return;
    }
    if (result.feedbackRecorded) {
      // 归属反馈回执是终态：不建 turn，不该等回答。
      _snack('已记录归属反馈');
    } else if (!result.isQueued) {
      _snack('消息已提交，但服务端未返回任务号');
    }
    await _reload();
  });

  Future<void> _complete() => _runAction(() async {
    try {
      final d = await widget.complete();
      if (!mounted) return;
      setState(() => _detail = d);
      _snack('已标记完成');
    } on HttpError catch (e) {
      // 服务端对非 active 的 work 返回 404（不是幂等 200）。重复点击时
      // 「目标状态已达成」，应刷新而不是报错。
      if (e.isNotFound) {
        await _refreshDetail();
        if (mounted) _snack('该工作已结束');
        return;
      }
      rethrow;
    }
  });

  Future<void> _stop() => _runAction(() async {
    try {
      final d = await widget.stop();
      if (!mounted) return;
      setState(() => _detail = d);
      _snack('已停止');
    } on HttpError catch (e) {
      if (e.isNotFound) {
        await _refreshDetail();
        if (mounted) _snack('该工作已结束');
        return;
      }
      rethrow;
    }
  });

  Future<void> _resolve(MiniappConfirmation card, String action) =>
      _runAction(() async {
        try {
          await widget.resolveConfirmation(card.id, action);
          if (!mounted) return;
          setState(() => _resolved.add(card.id));
          _snack('已提交：$action');
          await _refreshDetail();
        } on HttpError catch (e) {
          if (e.isNotFound) {
            // 404 = 非本人 / 已处理 / 已过期（服务端刻意统一，避免存在性探针）。
            // 目标状态已达成 → 标记为已处理，不报错。
            if (!mounted) return;
            setState(() => _resolved.add(card.id));
            _snack('这张确认已处理过了');
            await _refreshDetail();
            return;
          }
          rethrow;
        }
      });

  /// 选择并上传附件。
  ///
  /// ## 为什么选择与上传在同一个动作里
  ///
  /// 服务端只有「上传」这一个端点（没有「先登记再上传」的两步）。选中后立即
  /// 上传，用户不必再点一次「开始上传」——少一个可遗忘的步骤。
  ///
  /// ## 多选时为什么逐个上传而不是并发
  ///
  /// 服务端按顺序写 workspace（同名会触发冲突策略），并发上传同一目录会让
  /// 冲突判定互相竞争。逐个上传的代价可接受（用户看得见进度），换来行为可预期。
  Future<void> _upload() async {
    final upload = widget.onUploadFile;
    if (upload == null || _uploading) return;

    // 文件选择器：走 spb_platform（页面不直接 import 插件）。
    // 返回空 = 用户取消 / 平台不支持，两者都是预期内结果，不是错误。
    final picked = await pickFilesForOverlay();
    if (picked.isEmpty || !mounted) return;

    setState(() => _uploading = true);
    var done = 0;
    final failures = <String>[];
    try {
      for (final f in picked) {
        try {
          final bytes = await f.readBytes();
          await upload(filename: f.name, bytes: bytes);
          done++;
        } on SpbError catch (e) {
          // 单个文件失败不阻断整批：与 quick capture 的「部分失败」语义一致。
          failures.add('${f.name}：${e.message}');
        } on Object catch (e) {
          // readBytes 可能抛（文件在选中后被删除/无权限）——那是本地错误，
          // 不是 SpbError，但同样只影响这一个文件。
          failures.add('${f.name}：读取失败');
          SpbLog.warn('读取待上传文件失败', {'name': f.name, 'error': '$e'});
        }
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }

    if (!mounted) return;
    if (failures.isEmpty) {
      _snack('已上传 $done 个文件');
    } else {
      _snack('已上传 $done 个，${failures.length} 个失败：${failures.join('；')}');
    }
    // 无论成败都重拉：成功时列表多出产物；部分失败时也可能已有部分落盘，
    // 重拉能让用户看到真实状态，而不是我们猜的。
    await _reload();
  }

  Future<void> _download(MiniappArtifact artifact) async {
    if (_downloading.contains(artifact.id)) return;
    setState(() => _downloading.add(artifact.id));
    try {
      final bytes = await widget.downloadArtifact(artifact.id);
      final path = await widget.saveArtifact(artifact.name, bytes);
      if (mounted) _snack('已保存到 $path');
    } on SpbError catch (e) {
      // ## 下载失败是常态，不是异常情况
      //
      // 事件投影出的产物 id 可能是服务端合成的 `"<group_id>:<relative_path>"`
      // （payload 无 `ufs_file_id` 时），这种 id UFS 查不到 → 404。
      // 故给用户一句能理解的提示即可，不要把它当成「功能坏了」。
      if (mounted) _snack('下载失败：${e.message}');
    } finally {
      if (mounted) setState(() => _downloading.remove(artifact.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;

    if (detail == null && _loading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(
          key: ValueKey('miniapp-work-loading'),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (detail == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
          key: const ValueKey('miniapp-work-error'),
          child: Padding(
            padding: SpbSpacing.pagePadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: SpbSpacing.xxl,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: SpbSpacing.sm),
                Text(
                  '加载失败：${_error?.message ?? '未知错误'}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: SpbSpacing.md),
                FilledButton(
                  key: const ValueKey('miniapp-work-retry'),
                  onPressed: _reload,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      key: const ValueKey('miniapp-work-detail-page'),
      appBar: AppBar(
        title: Text(detail.title.isEmpty ? widget.title : detail.title),
        actions: [
          // 上传附件：只在注入了实现时展示（只读用法不显示）。
          if (widget.onUploadFile != null)
            IconButton(
              key: const ValueKey('miniapp-work-upload'),
              tooltip: '上传附件',
              icon: _uploading
                  ? const SizedBox(
                      width: SpbSpacing.lg,
                      height: SpbSpacing.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              onPressed: _uploading ? null : _upload,
            ),
          IconButton(
            key: const ValueKey('miniapp-work-refresh'),
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: SpbSpacing.pagePadding,
                children: [
                  _header(detail),
                  if (detail.steps.isNotEmpty) ...[
                    const SizedBox(height: SpbSpacing.lg),
                    const SectionTitle('步骤'),
                    for (final s in detail.steps) _StepTile(step: s),
                  ],
                  if (detail.pendingConfirmations.isNotEmpty) ...[
                    const SizedBox(height: SpbSpacing.lg),
                    const SectionTitle('待确认'),
                    for (final c in detail.pendingConfirmations)
                      _ConfirmationCard(
                        key: ValueKey('miniapp-confirmation-${c.id}'),
                        card: c,
                        busy: _acting,
                        resolved: _resolved.contains(c.id),
                        onResolve: (action) => _resolve(c, action),
                      ),
                  ],
                  if (_artifacts.isNotEmpty) ...[
                    const SizedBox(height: SpbSpacing.lg),
                    const SectionTitle('产物'),
                    for (final a in _artifacts)
                      _ArtifactTile(
                        key: ValueKey('miniapp-artifact-${a.id}'),
                        artifact: a,
                        downloading: _downloading.contains(a.id),
                        onDownload: () => _download(a),
                      ),
                  ],
                  if (_events.isNotEmpty) ...[
                    const SizedBox(height: SpbSpacing.lg),
                    const SectionTitle('事件'),
                    for (final e in _events)
                      _EventTile(
                        key: ValueKey('miniapp-event-${e.id}'),
                        event: e,
                      ),
                  ],
                  if (detail.canComplete || detail.canStop) ...[
                    const SizedBox(height: SpbSpacing.lg),
                    _actions(detail),
                  ],
                  const SizedBox(height: SpbSpacing.lg),
                ],
              ),
            ),
          ),
          if (detail.canSendMessage) _composer(),
        ],
      ),
    );
  }

  Widget _header(MiniappWorkDetail detail) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SpbSpacing.sm,
                vertical: SpbSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(SpbRadius.pill),
              ),
              child: Text(
                detail.displayStatus,
                key: const ValueKey('miniapp-work-status'),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            if (detail.progress.hasSteps)
              Text(
                '${detail.progress.completed}/${detail.progress.total}',
                key: const ValueKey('miniapp-work-progress'),
                style: textTheme.labelMedium,
              ),
          ],
        ),
        if (detail.goal != null && detail.goal!.isNotEmpty) ...[
          const SizedBox(height: SpbSpacing.sm),
          Text('目标：${detail.goal!}', style: textTheme.bodySmall),
        ],
        if (detail.progress.hasSteps) ...[
          const SizedBox(height: SpbSpacing.sm),
          LinearProgressIndicator(value: detail.progress.fraction),
        ],
        if (detail.latestResultText != null) ...[
          const SizedBox(height: SpbSpacing.md),
          Card(
            child: Padding(
              padding: SpbSpacing.cardPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    detail.latestResult?['title']?.toString() ?? '最新结果',
                    style: textTheme.labelMedium,
                  ),
                  const SizedBox(height: SpbSpacing.xs),
                  Text(
                    detail.latestResultText!,
                    key: const ValueKey('miniapp-work-latest-result'),
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _actions(MiniappWorkDetail detail) {
    return Row(
      children: [
        if (detail.canComplete)
          FilledButton.icon(
            key: const ValueKey('miniapp-work-complete'),
            onPressed: _acting ? null : _complete,
            icon: const Icon(Icons.check),
            label: const Text('标记完成'),
          ),
        if (detail.canStop) ...[
          const SizedBox(width: SpbSpacing.sm),
          OutlinedButton.icon(
            key: const ValueKey('miniapp-work-stop'),
            onPressed: _acting ? null : _stop,
            icon: const Icon(Icons.stop),
            label: const Text('停止'),
          ),
        ],
      ],
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(SpbSpacing.md),
        child: _MessageInput(enabled: !_acting, onSubmit: _send),
      ),
    );
  }
}

/// 底部消息输入（详情页专用）。
///
/// 不复用 `MessageComposer`：那个组件带「Enter 提交 / Shift+Enter 换行」的桌面
/// 键盘约定与自动聚焦，而小程序/移动端是触摸输入，回车即换行。语义不同，
/// 强行复用会让移动端用户误发消息。
class _MessageInput extends StatefulWidget {
  const _MessageInput({required this.enabled, required this.onSubmit});

  final bool enabled;
  final Future<void> Function(String input) onSubmit;

  @override
  State<_MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<_MessageInput> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('miniapp-work-message-field'),
            controller: _controller,
            enabled: widget.enabled,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: '补充要求…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: SpbSpacing.sm),
        IconButton.filled(
          key: const ValueKey('miniapp-work-message-send'),
          onPressed: widget.enabled ? _submit : null,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step});

  final MiniappStep step;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (step.status) {
      'completed' => (Icons.check_circle, scheme.primary),
      'skipped' => (Icons.remove_circle_outline, scheme.outline),
      'failed' => (Icons.error, scheme.error),
      'running' => (Icons.play_circle, scheme.tertiary),
      _ => (Icons.circle_outlined, scheme.outline),
    };

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: SpbSpacing.lg, color: color),
      title: Text(step.title),
      subtitle: step.description.isEmpty ? null : Text(step.description),
    );
  }
}

/// 确认卡（小程序侧）。
class _ConfirmationCard extends StatelessWidget {
  const _ConfirmationCard({
    super.key,
    required this.card,
    required this.busy,
    required this.resolved,
    required this.onResolve,
  });

  final MiniappConfirmation card;
  final bool busy;
  final bool resolved;
  final void Function(String action) onResolve;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: SpbSpacing.sm),
      color: resolved ? scheme.surfaceContainerHighest : null,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(card.title, style: Theme.of(context).textTheme.titleSmall),
            if (card.description != null && card.description!.isNotEmpty) ...[
              const SizedBox(height: SpbSpacing.xs),
              Text(
                card.description!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (card.requiredInputs.isNotEmpty) ...[
              const SizedBox(height: SpbSpacing.xs),
              for (final i in card.requiredInputs)
                Text(
                  '· ${i.label}${i.required ? '（必填）' : ''}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
            ],
            const SizedBox(height: SpbSpacing.sm),
            Wrap(
              spacing: SpbSpacing.sm,
              children: [
                for (final o in card.options)
                  // 推荐项用实心按钮，其余描边——减少误点。
                  o.recommended
                      ? FilledButton(
                          key: ValueKey('miniapp-confirm-${card.id}-${o.key}'),
                          onPressed: busy || resolved
                              ? null
                              : () => onResolve(o.key),
                          child: Text(o.label),
                        )
                      : OutlinedButton(
                          key: ValueKey('miniapp-confirm-${card.id}-${o.key}'),
                          onPressed: busy || resolved
                              ? null
                              : () => onResolve(o.key),
                          child: Text(o.label),
                        ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 产物条目（含下载）。
class _ArtifactTile extends StatelessWidget {
  const _ArtifactTile({
    super.key,
    required this.artifact,
    required this.downloading,
    required this.onDownload,
  });

  final MiniappArtifact artifact;
  final bool downloading;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(switch (artifact.type) {
        'image' => Icons.image_outlined,
        'prototype' => Icons.web_outlined,
        'document' => Icons.description_outlined,
        _ => Icons.insert_drive_file_outlined,
      }, size: SpbSpacing.lg),
      title: Text(
        artifact.name.isEmpty ? artifact.id : artifact.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${artifact.type} · ${_humanBytes(artifact.sizeBytes)}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
      trailing: downloading
          ? const SizedBox(
              width: SpbSpacing.lg,
              height: SpbSpacing.lg,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              key: ValueKey('miniapp-artifact-download-${artifact.id}'),
              tooltip: '下载',
              icon: const Icon(Icons.download),
              onPressed: onDownload,
            ),
    );
  }
}

/// 事件条目。
class _EventTile extends StatelessWidget {
  const _EventTile({super.key, required this.event});

  final MiniappWorkEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = event.text;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        switch (event.eventType) {
          'error' => Icons.error_outline,
          'message' => Icons.chat_bubble_outline,
          'user_message' => Icons.person_outline,
          _ => Icons.circle_outlined,
        },
        size: SpbSpacing.lg,
        color: event.eventType == 'error' ? scheme.error : null,
      ),
      title: Text(event.eventType),
      subtitle: text.isEmpty ? null : Text(text, maxLines: 4),
    );
  }
}

/// 人类可读的字节数。
String _humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
