import 'package:flutter/widgets.dart';

/// 时间线展示行的定位键注册表（`GlobalKey` + 回收）。
///
/// ## 为什么单独一个类，而不是页面里的一个 `Map` 字段
///
/// 它是**正确性核心**：`GlobalKey` 必须「同一逻辑行跨重建保持同一实例」
/// （否则 `KeyedSubtree` 会卸载重挂，丢失滚动位置），又必须「不在时间线上的
/// 行及时回收」（否则跨 group 切换持续累积，且键不再有对应 Element）。
/// 这两条相互拉扯——抽出来才能在无 widget 的环境里逐条钉住（issue #39）。
///
/// ## 为什么用 `GlobalKey` 而不是自己算偏移量
///
/// 时间线是**变高**列表（消息长度、文件卡、批量卡各不相同），自己累加高度
/// 去推算目标偏移几乎必然不准——`ListView.builder` 对未构建项的高度只能
/// 估算，且估算值会在后续帧里修正。`GlobalKey` + `Scrollable.ensureVisible`
/// 交给框架处理：对已构建项直接用真实几何，对未构建项先滚到附近再重试。
///
/// 用 `item.id` 而非下标作键：搜索期间新消息可能到达，下标会整体平移，而
/// 下标错位会让「跳到命中项」跳到别人身上。
///
/// ## ⚠️ 「行的键」与「成员的定位入口」必须分开存（一次真实事故）
///
/// 曾经只用一张 `item.id → GlobalKey` 表，并在 `keyFor(ids)` 里把**批量卡的
/// 每个成员**都直接写成同一个键实例：
///
/// ```dart
/// final key = _keys.putIfAbsent(ids.first, GlobalKey.new);
/// for (final id in ids.skip(1)) _keys[id] = key;   // ← 缺陷所在
/// ```
///
/// 它把「批量卡的每个成员都能被搜索定位到这张卡」与「这张卡的
/// `GlobalKey` 实例」混为一谈。一旦**同一段文件被拆成多行**，多行就会拿到
/// 同一个 `GlobalKey`，Flutter 抛
/// `Multiple widgets used the same GlobalKey`，后出现的那几行**渲染为空白**
/// ——而 `recycle` 拦不住（它按 id 是否在时间线上过滤，那些 id 确实还在）。
///
/// 拆分是真实会发生的，有两条路径：
///
/// 1. **缓冲区裁剪**（`ChatStreamController._trimBuffer`，上限 2000 条）从
///    头部丢弃事件，边界可能落在批量卡中间：7 个文件剩 4 个，不足
///    `FILE_BATCH_MIN_COUNT`（5）→ 退回 4 个 `SingleItemRow`；
/// 2. **翻页拼接**：`loadOlder` 前插的一页与缓冲区头部同 turn 同秒时会**合并**
///    成批量卡；页边界若切在批中间，头部那段先以「不足阈值」落单，补上更早
///    那一页后又并回批量卡。用户「滚上去、再滚下来」就能让它在两种形态间
///    反复翻转。
///
/// 故现在把两个概念分开：
///
/// | 表 | 内容 | 用途 |
/// |---|---|---|
/// | [_owned] | 行主键（`ids.first`）→ `GlobalKey` | **真正挂在 widget 上的键**，一行一个，绝不共享 |
/// | [_aliases] | 成员 id → 行主键 | 只供 `operator []` 查（批量卡内任一成员都要能定位到那张卡） |
///
/// 查表时先看 [_owned] 再看 [_aliases]，于是「成员」永远不会成为键的所有者；
/// 同一批被拆成 N 行时，每行按自己的 `ids.first` 各自 `putIfAbsent`，拿到的是
/// N 个**不同**的键。
class RowLocateRegistry {
  /// 行主键（[keyFor] 的 `ids.first`）→ 该行的 `GlobalKey`。
  final _owned = <String, GlobalKey>{};

  /// 成员 id → 所属行主键（批量卡的非首成员）。
  ///
  /// 存**主键名**而非 `GlobalKey` 实例：回收时只要按「主键是否还在」过滤一次，
  /// 别名就自动失效，不会留下指向已回收键的悬空条目。
  final _aliases = <String, String>{};

  /// 当前登记的**行数**（仅供测试断言回收是否生效）。
  ///
  /// 不含别名：别名不是行，把它们算进来会让「7 成员批量卡」被数成 7 行。
  @visibleForTesting
  int get length => _owned.length;

  /// 取（必要时创建）一行的定位键。
  ///
  /// [ids] 是**同一渲染行**占用的全部 `item.id`（见 `locateIdsOf`）：
  /// `ids.first` 是该行的主键（单条即它自己的 id；批量卡即首成员 id），
  /// 其余是**别名**——它们渲染在同一张卡里，搜到其中任何一个都应定位到那张卡。
  ///
  /// 只有主键能成为键的所有者。别名只登记查询入口，**不**复制键实例，故同一
  /// 段文件被拆成多行时，各行按自己的主键拿到各自的键（见类文档的事故记录）。
  GlobalKey keyFor(List<String> ids) {
    assert(ids.isNotEmpty, 'ids 不得为空：至少要有主键');
    final owner = ids.first;
    final key = _owned.putIfAbsent(owner, GlobalKey.new);
    // 主键不再作为别名存在（否则它自己的行被回收后会从别名里取到旧键）。
    _aliases.remove(owner);
    for (final id in ids.skip(1)) {
      if (id == owner) continue;
      _aliases[id] = owner;
      // 它上一帧可能是一行自己的主键（如批量卡被拆散后又合并回来）。
      // 现在它只是别名，那份旧键已无 widget 引用，必须放掉——否则 `[]`
      // 会按「主键优先」返回那个悬空的键。
      _owned.remove(id);
    }
    return key;
  }

  /// 查某条 `item.id` 对应的定位键（未登记则为 null）。
  ///
  /// 先查主键再查别名：成员 id 只有在该行**当前仍以它为主键之外的形式存在**
  /// 时才可解析到键。
  GlobalKey? operator [](String id) {
    final own = _owned[id];
    if (own != null) return own;
    final owner = _aliases[id];
    return owner == null ? null : _owned[owner];
  }

  /// 回收不在 [liveIds] 里的键。
  ///
  /// ## 为什么不能清空重建
  ///
  /// 清空会让**全部**行的 `GlobalKey` 变化，`KeyedSubtree` 随之卸载重挂——
  /// 滚动位置丢失、整棵子树重建（每帧一次的话就是持续卡顿）。故只回收
  /// **确实已不在时间线上**的 id：它们本来就没有 Element 可保留。
  ///
  /// ## 别名随主键一起失效
  ///
  /// 主键被回收（该行已不在时间线上）后，指向它的别名一并删除。否则下一帧
  /// 若那几个成员以**独立行**重新出现，`keyFor` 会从别名里取到已回收行的键
  /// ——正是类文档里那个事故。
  ///
  /// ⚠️ 这也意味着「批量卡的首成员被裁掉」时整行的键会被丢弃（该行身份已变：
  /// 首成员换了，`ValueKey` 也随之变），下一帧按新首成员建新键。
  void recycle(Set<String> liveIds) {
    if (_owned.isEmpty && _aliases.isEmpty) return;
    _owned.removeWhere((id, _) => !liveIds.contains(id));
    _aliases.removeWhere(
      (alias, owner) => !liveIds.contains(alias) || !_owned.containsKey(owner),
    );
  }
}
