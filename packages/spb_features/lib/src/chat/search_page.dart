import 'dart:async';

import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';
import 'package:spb_models/spb_models.dart';

/// 搜索执行的签名（由 app 层注入真实实现）。
///
/// ## 为什么注入而不是直接收 `ChatApi`
///
/// 本页只做渲染与交互（见 `chat.dart` 的分层说明）。`ChatApi.search` 需要
/// `userId`，而 userId 来自认证状态——页面不该知道「我是谁」是怎么解析出来的
/// （那要走 `GET /api/auth/me`，且不同端的解析时机不同）。
///
/// 注入后页面在 widget test 里可以完整验证，不需要起 HTTP mock。
typedef SearchChat = Future<List<ChatSearchHit>> Function(
  String query, {
  int? limit,
});

/// 搜索页：输入关键字 → 展示命中片段 → 点击跳转。
///
/// ## 与「过滤对话列表」的区别
///
/// 本页搜的是**消息正文**（服务端 `SearchChatTurnsByText`，LIKE 匹配
/// `chat_turns.input_text`），不是对话标题。故命中项展示的是「哪句话命中了」，
/// 而不是「哪个对话」——同一个对话可能命中多条。
///
/// ## 为什么不做本地过滤
///
/// 本地只有当前已加载的对话列表（offset 分页，通常几十条），拿它过滤会给出
/// **看起来像全量、实际是残缺**的结果。搜索必须走服务端。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.search,
    this.onOpenHit,
    this.debounce = const Duration(milliseconds: 300),
  });

  /// 执行搜索（注入）。
  final SearchChat search;

  /// 点击命中项的回调。参数是命中项所属的 group id。
  ///
  /// 页面**不做路由**：跳转目标由调用方决定（桌面端是 `/chat/:groupId`，
  /// 移动端将来可能换成 push 一个新页面）。为 null 时条目不可点。
  final void Function(ChatSearchHit hit)? onOpenHit;

  /// 输入防抖时长。
  ///
  /// ## 为什么要防抖
  ///
  /// 搜索是服务端 LIKE 查询（`%pattern%`，无法走索引）。逐字符发请求意味着
  /// 输入「报错排查」会打 4 次全表扫描，而前 3 次的结果用户根本看不到就被
  /// 后一次覆盖了。
  ///
  /// 300ms 是「打字停顿」的经验值：比它短会把连打当成多次搜索，比它长会
  /// 让人觉得「打了字没反应」。
  final Duration debounce;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();

  /// 防抖计时器。新输入到来时取消上一次。
  Timer? _debounceTimer;

  /// 已发出的搜索序号。
  ///
  /// ## 为什么需要它（而不只是取消 Timer）
  ///
  /// 防抖只挡住「还没发出去的」请求，挡不住**已在途**的响应：用户输入
  /// 「报」→ 请求 A 发出；300ms 后又输入「错」→ 请求 B 发出。若 A 比 B
  /// **晚**返回（网络抖动完全可能），A 的结果会覆盖 B 的——列表显示的是
  /// 「报」的结果，而输入框里是「报错」。
  ///
  /// 故每个请求带序号，响应回来时只接受**最新**的那个。
  int _requestSeq = 0;

  List<ChatSearchHit> _hits = const [];
  bool _loading = false;

  /// 当前展示的结果对应的查询词。
  ///
  /// 用它判断「是否需要搜」：输入回到与结果相同的词时不必重搜。
  String _lastQuery = '';

  /// 是否已搜过（用于区分「还没搜」与「搜了但没结果」）。
  bool _searched = false;

  SpbError? _error;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounceTimer?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      // 清空输入 = 退出搜索状态，而不是「搜空串」。
      //
      // 服务端对空 q 返回空列表，但本地直接清空更好：用户删光输入时不该看到
      // 一次多余的往返，也不该残留上次的结果。
      setState(() {
        _hits = const [];
        _lastQuery = '';
        _searched = false;
        _error = null;
        _loading = false;
        // 序号自增，让在途响应失效（否则它回来会把空列表覆盖成旧结果）。
        _requestSeq++;
      });
      return;
    }
    _debounceTimer = Timer(widget.debounce, () => _run(query));
  }

  /// 立即搜索（回车 / 点搜索按钮），不等防抖。
  void _submit() {
    _debounceTimer?.cancel();
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    _run(query);
  }

  Future<void> _run(String query) async {
    if (!mounted) return;
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final hits = await widget.search(query);
      // 丢弃过期响应（见 _requestSeq 说明）。
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _hits = hits;
        _lastQuery = query;
        _searched = true;
        _loading = false;
      });
    } on SpbError catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = e;
        _loading = false;
        // 失败也算「搜过了」：否则会同时显示「还没搜」的空状态与错误提示。
        _searched = true;
        _lastQuery = query;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const ValueKey('search-field'),
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索消息内容',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          IconButton(
            key: const ValueKey('search-submit'),
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: _submit,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ErrorState(
        message: _error!.message,
        onRetry: () => _run(_lastQuery),
      );
    }

    if (_hits.isEmpty) {
      return EmptyState(
        icon: Icons.search_outlined,
        message: _searched ? '没有找到「$_lastQuery」' : '输入关键字搜索消息内容',
      );
    }

    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final hit = _hits[index];
        return _HitTile(
          key: ValueKey('search-hit-${hit.turnId}'),
          hit: hit,
          query: _lastQuery,
          onTap: widget.onOpenHit == null ? null : () => widget.onOpenHit!(hit),
        );
      },
    );
  }
}

/// 单条命中项。
class _HitTile extends StatelessWidget {
  const _HitTile({
    super.key,
    required this.hit,
    required this.query,
    this.onTap,
  });

  final ChatSearchHit hit;

  /// 当前查询词，用于高亮命中片段。
  final String query;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListTile(
      onTap: onTap,
      title: Text(
        hit.displayTitle,
        overflow: TextOverflow.ellipsis,
        style: textTheme.titleSmall,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: SpbSpacing.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 命中片段：服务端在 200 字符处截断，故可能不完整。
            HighlightedText(
              text: hit.inputText,
              query: query,
              style: textTheme.bodyMedium,
              maxLines: 3,
              highlightStyle: textTheme.bodyMedium?.copyWith(
                backgroundColor: scheme.primaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (hit.createdAt != null) ...[
              const SizedBox(height: SpbSpacing.xs),
              Text(
                _relativeTime(hit.createdAt!),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      isThreeLine: true,
    );
  }

  /// 相对时间（同对话列表的呈现方式，保持两处一致）。
  static String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}'
        '-${t.day.toString().padLeft(2, '0')}';
  }
}
