import 'package:meta/meta.dart';

/// 有界的 groupId → title 缓存（docs/memory-audit.md G3）。
///
/// ## 为什么抽出来
///
/// 两端 router 各有 4 处裸 `Map<String, String> _titles`（待确认收件箱 × 2、
/// 习惯页 × 2）：`containsKey` 只增不删，页面 State 存续期内无界累积。
/// 单条只是「短字符串 id → 短字符串标题」，但四份同构代码各养一个无界 Map
/// ——抽成共享的有界实现，一处改、四处受益（§6.41 同一取向：同一份计算被
/// 抄多遍时收敛成纯逻辑）。
///
/// ## 取值语义与裸 Map 完全一致
///
/// - [titleOf]：等价于 `_titles[gid]`——miss 返回 null（卡片展示「未知对话」）；
/// - [contains]：等价于 `_titles.containsKey`——预取循环据此跳过已有条目；
/// - [remember]：等价于 `_titles[gid] = title`，并在超容量时淘汰最旧条目。
///
/// ## 淘汰的语义安全性（诚实记录折衷）
///
/// 被淘汰的条目下次预取会**重新拉取**一次标题（一次 HTTP），随后重新记住
/// ——仅多一次请求，无任何行为风险。淘汰按「最旧写入」序（[LinkedHashMap]
/// 保插入序），不走 LRU：预取循环天然按「最近看见的 group」写入，两者在本
/// 场景下几乎重合，而 LRU 的成本（维护双向链表）不值得。
///
/// 容量默认 [defaultCapacity]：远超单页涉及的对话数（待确认/习惯列表上限
/// 50 条），内存上几 KB 封顶。
final class GroupTitleCache {
  GroupTitleCache({this.capacity = defaultCapacity});

  /// 默认容量：覆盖「单页列表 + 跨页翻阅」的量级，几 KB 内存封顶。
  static const int defaultCapacity = 512;

  /// 单条目容量上限。超出后 [remember] 淘汰最旧写入的 key。
  ///
  /// ⚠️ 这是**上限**而非预分配；构造时 Map 为空。
  final int capacity;

  /// `LinkedHashMap` 保插入序：[keys.first] 即最旧写入的 key。
  final Map<String, String> _titles = {};

  /// 是否已记住 [groupId] 的标题（预取循环据此跳过，避免重复拉取）。
  bool contains(String groupId) => _titles.containsKey(groupId);

  /// 同步查询标题；miss 返回 null（调用方展示「未知对话」占位）。
  String? titleOf(String groupId) => _titles[groupId];

  /// 记住一条标题；超容量时淘汰最旧写入的条目。
  ///
  /// 重复写入同一 key 只刷新值、不改变次序（LinkedHashMap 语义），也不会
  /// 触发淘汰（容量不变）。
  void remember(String groupId, String title) {
    _titles[groupId] = title;
    if (_titles.length > capacity) {
      _titles.remove(_titles.keys.first);
    }
  }

  /// 当前条目数（测试用）。
  @visibleForTesting
  int get length => _titles.length;

  /// 清空（页面销毁 / 登出时可调用；两端 router 页面 State 随路由销毁，
  /// 目前无需显式接线，保留给将来需要主动复位时使用）。
  void clear() => _titles.clear();
}
