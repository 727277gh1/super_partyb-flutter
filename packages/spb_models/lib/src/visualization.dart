import 'chat_event.dart';

/// visualization.published 的 payload。只携带固定版本引用，不携带 Spec。
class VisualizationPublished {
  VisualizationPublished.fromJson(Map<String, dynamic> json)
    : eventVersion = _int(json['event_version']),
      artifactId = _str(json['artifact_id']),
      artifactKey = _str(json['artifact_key']),
      revision = _int(json['revision']),
      profile = _str(json['profile']),
      schemaVersion = _int(json['schema_version']),
      title = _str(json['title']),
      summary = _str(json['summary']);

  final int eventVersion;
  final String artifactId;
  final String artifactKey;
  final int revision;
  final String profile;
  final int schemaVersion;
  final String title;
  final String summary;

  /// 未知版本保留元数据，调用方不得按 v1 解释或降级到 latest。
  bool get isSupported =>
      eventVersion == 1 &&
      profile == 'partyb.readonly' &&
      schemaVersion == 1 &&
      artifactId.isNotEmpty &&
      revision > 0;
}

/// 列表摘要（snake_case），revision 是列表读取时的最新版本。
class VisualizationSummary {
  VisualizationSummary.fromJson(Map<String, dynamic> json)
    : artifactId = _str(json['artifact_id']),
      artifactKey = _str(json['artifact_key']),
      groupId = _str(json['group_id']),
      revision = _int(json['revision']),
      profile = _str(json['profile']),
      schemaVersion = _int(json['schema_version']),
      title = _str(json['title']),
      summary = _str(json['summary']),
      createdAt = DateTime.tryParse(_str(json['created_at'])),
      updatedAt = DateTime.tryParse(_str(json['updated_at']));

  final String artifactId;
  final String artifactKey;
  final String groupId;
  final int revision;
  final String profile;
  final int schemaVersion;
  final String title;
  final String summary;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class VisualizationPage {
  VisualizationPage.fromJson(Map<String, dynamic> json)
    : items = List.unmodifiable(
        _objects(json['items']).map(VisualizationSummary.fromJson),
      ),
      nextCursor = _str(json['next_cursor']);

  final List<VisualizationSummary> items;
  final String nextCursor;
}

/// 固定 revision 的内容快照。Schema/组件白名单由服务端 Profile 维护。
class VisualizationRevision {
  VisualizationRevision.fromJson(Map<String, dynamic> json)
    : artifactId = _str(json['artifact_id']),
      artifactKey = _str(json['artifact_key']),
      groupId = _str(json['group_id']),
      revision = _int(json['revision']),
      turnId = _str(json['turn_id']),
      eventId = _str(json['event_id']),
      profile = _str(json['profile']),
      schemaVersion = _int(json['schema_version']),
      title = _str(json['title']),
      summary = _str(json['summary']),
      contentHash = _str(json['content_hash']),
      status = _str(json['status']),
      createdAt = DateTime.tryParse(_str(json['created_at'])),
      dataAsOf = DateTime.tryParse(_str(json['data_as_of'])),
      spec = Map.unmodifiable(_object(json['spec'])),
      sources = List.unmodifiable(
        _objects(json['sources']).map(VisualizationSource.fromJson),
      );

  final String artifactId;
  final String artifactKey;
  final String groupId;
  final int revision;
  final String turnId;
  final String eventId;
  final String profile;
  final int schemaVersion;
  final String title;
  final String summary;
  final String contentHash;
  final String status;
  final DateTime? createdAt;
  final DateTime? dataAsOf;
  final Map<String, dynamic> spec;
  final List<VisualizationSource> sources;

  bool get isSupported => profile == 'partyb.readonly' && schemaVersion == 1;
}

class VisualizationSource {
  VisualizationSource.fromJson(Map<String, dynamic> json)
    : label = _str(json['label']),
      url = json['url'] is String ? json['url'] as String : null;

  final String label;
  final String? url;
}

/// 恢复页使用独立水位，不能用普通 SSE 游标替代。
class VisualizationRecoveryPage {
  VisualizationRecoveryPage.fromJson(Map<String, dynamic> json)
    : items = List.unmodifiable(
        // 恢复页不能跳过损坏的记录再推进水位，否则遗漏将无法自动补齐。
        (json['items'] as List).map(
          (item) => ChatEvent.fromJson(Map<String, dynamic>.from(item as Map)),
        ),
      ),
      throughGlobalSeq = json['through_global_seq'] as int,
      nextAfterGlobalSeq = json['next_after_global_seq'] as int,
      hasMore = json['has_more'] as bool;

  final List<ChatEvent> items;
  final int throughGlobalSeq;
  final int nextAfterGlobalSeq;
  final bool hasMore;
}

String _str(Object? value) => value is String ? value : '';
int _int(Object? value) => value is int ? value : 0;
Map<String, dynamic> _object(Object? value) =>
    value is Map<String, dynamic> ? value : const {};
Iterable<Map<String, dynamic>> _objects(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>() : const [];
