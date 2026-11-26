/// 同步设置的**聚合形态**（设置页读写的最小单位）。
///
/// ## 为什么聚合而不是散成四个 provider
///
/// 设置页是**表单**：用户改几项、点保存，期望这几项**一起生效**（或一起不
/// 生效）。若每一项各自即时落盘，用户改到一半关掉页面就会留下一个混合状态
/// （新目录 + 旧范围），而「换目录要清同步状态」这条规则又要求目录写入与
/// 状态清空同事务——散着写会让这个事务无法成立。
///
/// 故：表单在内存里编辑，保存时一次性提交。
///
/// ## 字段与持久化的对应
///
/// | 字段 | 落库位置 |
/// |---|---|
/// | [localRoot] | `sync_bindings` 表（**不是**偏好表）——见 `DriftSyncStateStore.bindLocalRoot` |
/// | [scope] / [filter] / [sinceDays] / [auto] | `preferences` 表 |
///
/// 目录单独落表是既有设计：它必须与「清空同步状态」同事务。
library;

import 'deliverable_sync.dart';
import 'sync_auto_config.dart';
import 'sync_scope_config.dart';

/// 同步设置。
class SyncSettings {
  const SyncSettings({
    this.localRoot,
    this.scope = const SyncScopeConfig(),
    this.filter = const SyncFilterConfig(),
    this.sinceDays,
    this.auto = AutoSyncConfig.disabled,
  });

  /// 本地同步目录。null = 尚未选择（此时不能同步）。
  final String? localRoot;

  /// 同步范围（全部 / 勾选若干 / 单 group）。
  final SyncScopeConfig scope;

  /// 过滤配置（媒体开关 + 单文件上限）。
  final SyncFilterConfig filter;

  /// 只拉最近 N 天内变动的交付物；null = 不限历史。
  ///
  /// 见 `sync_cursor.dart` 的 `effectiveCursor`：`null` 与 `0` 都表示不限。
  final int? sinceDays;

  /// 自动同步配置（启动时 / 周期）。
  ///
  /// 默认 [AutoSyncConfig.disabled]——自动同步**默认关闭**。首次全量同步在
  /// 生产实测是 5666 条 / 4.7 GB，静默替用户拉这么多不可接受。
  final AutoSyncConfig auto;

  bool get hasLocalRoot => localRoot != null && localRoot!.trim().isNotEmpty;

  /// 是否可执行同步（有目录 + 范围配置得通）。
  ///
  /// 单 group 模式没有 groupId，故不可同步——但它不该由设置页产出（见
  /// [SyncScopeConfig.isSingleGroup]）。
  bool get canSync {
    if (!hasLocalRoot) return false;
    final s = scope;
    if (s.isSingleGroup) return false;
    return true;
  }

  SyncSettings copyWith({
    String? localRoot,
    SyncScopeConfig? scope,
    SyncFilterConfig? filter,
    int? sinceDays,
    AutoSyncConfig? auto,
    bool clearSinceDays = false,
  }) => SyncSettings(
    localRoot: localRoot ?? this.localRoot,
    scope: scope ?? this.scope,
    filter: filter ?? this.filter,
    sinceDays: clearSinceDays ? null : (sinceDays ?? this.sinceDays),
    auto: auto ?? this.auto,
  );

  @override
  bool operator ==(Object other) =>
      other is SyncSettings &&
      other.localRoot == localRoot &&
      other.scope == scope &&
      other.filter.includeMedia == filter.includeMedia &&
      other.filter.maxFileSize == filter.maxFileSize &&
      other.sinceDays == sinceDays &&
      other.auto == auto;

  @override
  int get hashCode => Object.hash(
    localRoot,
    scope,
    filter.includeMedia,
    filter.maxFileSize,
    sinceDays,
    auto,
  );

  @override
  String toString() =>
      'SyncSettings(root: $localRoot, scope: $scope, '
      'media: ${filter.includeMedia}, maxSize: ${filter.maxFileSize}, '
      'sinceDays: $sinceDays, auto: $auto)';
}

/// 本地同步目录的总体统计（设置页「本地统计」展示）。
class LocalSyncStats {
  const LocalSyncStats({
    required this.groupCount,
    required this.fileCount,
    required this.totalBytes,
  });

  /// 本地目录数（只统计 group_id 形状的目录）。
  final int groupCount;

  /// 文件总数。
  final int fileCount;

  /// 总字节数。
  final int totalBytes;

  /// 空统计（目录不存在或尚未同步过）。
  static const empty = LocalSyncStats(
    groupCount: 0,
    fileCount: 0,
    totalBytes: 0,
  );

  bool get isEmpty => groupCount == 0 && fileCount == 0;

  @override
  bool operator ==(Object other) =>
      other is LocalSyncStats &&
      other.groupCount == groupCount &&
      other.fileCount == fileCount &&
      other.totalBytes == totalBytes;

  @override
  int get hashCode => Object.hash(groupCount, fileCount, totalBytes);

  @override
  String toString() =>
      'LocalSyncStats($groupCount 个目录, $fileCount 个文件, $totalBytes 字节)';
}
