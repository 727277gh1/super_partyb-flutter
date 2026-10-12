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
class RowLocateRegistry {
  final _keys = <String, GlobalKey>{};

  /// 当前登记的键数量（仅供测试断言回收是否生效）。
  @visibleForTesting
  int get length => _keys.length;

  /// 取（必要时创建）一行共用的定位键。
  ///
  /// [ids] 是**同一渲染行**占用的全部 `item.id`（见 `locateIdsOf`）：批量卡
  /// 的每个成员都映射到同一个键——它们渲染在同一张卡里，搜到批内任一成员
  /// 都应定位到那张卡，而不是退化成「请向上滚动」。
  ///
  /// 用 `putIfAbsent` 而非每次新建：同一逻辑行跨重建必须复用同一 `GlobalKey`。
  GlobalKey keyFor(List<String> ids) {
    final key = _keys.putIfAbsent(ids.first, GlobalKey.new);
    for (final id in ids.skip(1)) {
      _keys[id] = key;
    }
    return key;
  }

  /// 查某条 `item.id` 对应的定位键（未登记则为 null）。
  GlobalKey? operator [](String id) => _keys[id];

  /// 回收不在 [liveIds] 里的键。
  ///
  /// ## 为什么不能清空重建
  ///
  /// 清空会让**全部**行的 `GlobalKey` 变化，`KeyedSubtree` 随之卸载重挂——
  /// 滚动位置丢失、整棵子树重建（每帧一次的话就是持续卡顿）。故只回收
  /// **确实已不在时间线上**的 id：它们本来就没有 Element 可保留。
  void recycle(Set<String> liveIds) {
    if (_keys.isEmpty) return;
    _keys.removeWhere((id, _) => !liveIds.contains(id));
  }
}
