/// 同步范围配置（**持久化形态**，与运行时形态 [SyncScope] 分开）。
///
/// ## 为什么要分成两个类型
///
/// [SyncScope] 是**运行时**的范围（`SyncGroupScope` / `SyncWorkspaceScope` /
/// `SyncGroupsScope`），它已经确定了「本地怎么分层、状态键用哪个」，因此
/// 单 group 形态必须带 groupId。
///
/// 而设置页要持久化的是**用户的意图**，其中有一个合法状态在运行时无法表达：
/// 「非全部、且一个 group 都没勾」——那是用户**表单填到一半**的样子（他取消
/// 了「全部」但还没勾）。把它硬塞进 `SyncScope` 只能靠编造一个 groupId，
/// 于是「填到一半」会被当成「同步某个编造的 group」。
///
/// 故持久化层用本类型（允许空列表），在**执行同步时**才转成 [SyncScope]；
/// 转不过去时给出可操作的错误文案（见 [toScope]）。
library;

import 'dart:convert';

import 'package:spb_core/spb_core.dart';

import 'deliverable_sync.dart';

/// 用户的同步范围意图。
class SyncScopeConfig {
  const SyncScopeConfig({this.allGroups = true, this.groupIds = const []});

  /// 是否同步该用户**全部** group。
  final bool allGroups;

  /// 勾选的 group（仅当 [allGroups] 为 false 时有意义）。
  ///
  /// 保持有序（用户勾选顺序）以便 UI 稳定渲染；去重在 [copyWith] 里做。
  final List<String> groupIds;

  /// 默认：全部 group。
  ///
  /// ## 为什么默认是「全部」而不是「单个」
  ///
  /// 设置页/托盘是主入口，**没有 group 上下文**。默认单 group 会让
  /// 「选完目录立即同步」直接报错（缺 groupId），而用户并没有做错什么。
  static const SyncScopeConfig all = SyncScopeConfig();

  /// 是否为「单 group 模式」：非全部、且未勾选任何 group。
  ///
  /// 该状态**不能**由设置页产出（表单校验会拦住），只有程序化调用（如
  /// 从某个对话内触发同步）才会用到。
  bool get isSingleGroup => !allGroups && groupIds.isEmpty;

  /// 是否为「勾选若干」模式。
  bool get isSelectedGroups => !allGroups && groupIds.isNotEmpty;

  /// 转成运行时范围。
  ///
  /// [groupId] 只在「单 group 模式」下使用。
  ///
  /// ## 为什么转不过去时抛异常而不是退化
  ///
  /// 直觉上「非全部 + 空列表」可以退化成「全部」，但那是**危险**的一侧：
  /// 用户明明表达了「不要同步全部」（他关掉了那个开关），我们却去同步全部，
  /// 结果是**多下了一整个 workspace 的交付物**（生产实测 5666 条 / 4.7 GB），
  /// 而用户以为自己只是还没勾完。反过来退化成「什么都不同步」则是安全的一侧，
  /// 但那样用户点同步毫无反应、也没有解释。
  ///
  /// 故这里抛错，由上层把 [SpbError.message] 直接展示给用户——文案里写清
  /// 「该怎么做」。
  SyncScope toScope({String? groupId}) {
    if (allGroups) return const SyncWorkspaceScope();
    if (groupIds.isNotEmpty) return SyncGroupsScope(List.of(groupIds));

    final gid = groupId?.trim();
    if (gid == null || gid.isEmpty) {
      throw const PlatformError('同步范围未配置：请选择「全部对话」或至少勾选一个对话');
    }
    return SyncGroupScope(gid);
  }

  /// 表单校验：返回 null 表示可保存。
  ///
  /// 允许保存「非全部 + 空列表」（用户可能想先关掉全部再慢慢勾），但保存后
  /// 点同步会得到 [toScope] 的明确报错。这样「填到一半」不会被误当成合法意图。
  String? validate() => null;

  /// 序列化为持久化字符串。
  ///
  /// ## 为什么整个范围存成一个 JSON 而不是两个偏好键
  ///
  /// `allGroups` 与 `groupIds` 必须**一起**变：分开存会出现「全部=true 且勾了
  /// 三个」这种无法解释的组合（读侧不知道哪个优先）。存一个键天然保证原子性。
  ///
  /// 编码放在 domain 而非各 app：这是**领域类型的持久化格式**，两个 app
  /// 各写一份会漂移（一端加了字段，另一端读不出来却静默退回默认值）。
  String encode() =>
      jsonEncode({'all_groups': allGroups, 'group_ids': groupIds});

  /// 从持久化字符串解析；`null`/空串/损坏一律退回「全部」。
  ///
  /// ## 为什么损坏时退回「全部」而不是「什么都不勾」
  ///
  /// 「全部」是默认值，也是设置页主入口最可能想要的（它没有 group 上下文）。
  /// 退回「空列表」会让同步突然什么都不同步，而用户不知道为什么——那比
  /// 「多同步了一些」更难排查。
  ///
  /// 不抛异常：偏好是「配置」而非「数据」，一个坏值不该让设置页打不开。
  static SyncScopeConfig decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const SyncScopeConfig();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const SyncScopeConfig();
      final all = decoded['all_groups'];
      final ids = decoded['group_ids'];
      return SyncScopeConfig(
        allGroups: all is bool ? all : true,
        groupIds: ids is List
            ? ids.map((e) => e.toString()).toList()
            : const [],
      );
    } catch (e) {
      // 回退成「全部同步」——**用户看不见**的语义变化：他可能特意选了
      // 「只同步这几个对话」，但存的值坏了，于是所有对话都被拉下来。
      //
      // 记 warn（issue #45）：不回退成「什么都不同步」是因为「多同步一些」
      // 比「突然什么都不同步」好排查；但既然用户意图被丢弃了，就必须留痕。
      SpbLog.warn('同步范围偏好无法解析，回退成「全部同步」', {
        'raw_bytes': raw.length,
        'error': e.toString(),
      });
      return const SyncScopeConfig();
    }
  }

  SyncScopeConfig copyWith({bool? allGroups, List<String>? groupIds}) =>
      SyncScopeConfig(
        allGroups: allGroups ?? this.allGroups,
        // 去重但保持顺序：UI 反复勾选同一项不应产生重复 id。
        groupIds: groupIds == null ? this.groupIds : _dedupe(groupIds),
      );

  static List<String> _dedupe(List<String> ids) {
    final seen = <String>{};
    final out = <String>[];
    for (final id in ids) {
      final trimmed = id.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed)) out.add(trimmed);
    }
    return out;
  }

  @override
  bool operator ==(Object other) {
    if (other is! SyncScopeConfig) return false;
    if (other.allGroups != allGroups) return false;
    if (other.groupIds.length != groupIds.length) return false;
    for (var i = 0; i < groupIds.length; i++) {
      if (other.groupIds[i] != groupIds[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(allGroups, Object.hashAll(groupIds));

  @override
  String toString() =>
      allGroups ? 'SyncScopeConfig(all)' : 'SyncScopeConfig(groups: $groupIds)';
}
