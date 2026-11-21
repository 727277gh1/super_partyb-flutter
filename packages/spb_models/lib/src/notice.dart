/// 站内通知（`GET /me/notices` 的一项）。
///
/// 对应 Go 侧 `internal/notices/store.go` 的 `Notice`。字段名沿用服务端 snake_case
/// （与 `ChatConfirmation` 同一约定），**映射只发生在 spb_models**。
///
/// ## 与 ChatConfirmation 的关系
///
/// 不是同一件事：
///
/// - `ChatConfirmation` 是**卡片**——有状态机（pending/resolved/expired），10 分钟
///   后过期，过期即从「待办」里消失。
/// - `Notice` 是**通知**——持久事实，不会因为卡片过期而消失。它回答的是
///   「刚才发生过什么」，不是「现在还能不能点」。
///
/// 同一张确认卡会同时产生一条 `ChatConfirmation` 与一条 `Notice`。客户端据此
/// 在通知中心展示历史，同时仍按卡片的真实状态渲染按钮。
///
/// ## 对未知 kind 必须宽容
///
/// [kind] 是字符串而不是 enum：服务端会陆续加 kind（`turn_completed` 等），
/// 客户端不认识的值必须降级为通用展示，**不能抛异常**——否则一次服务端上线
/// 就会让旧客户端整个通知中心崩掉。
library;

class Notice {
  const Notice({
    required this.id,
    required this.kind,
    required this.severity,
    required this.title,
    required this.body,
    required this.createdAt,
    this.data = const {},
    this.groupId,
    this.readAt,
    this.updatedAt,
  });

  /// 通知 id。客户端本地判重（receipts）与服务端已读都用它。
  final String id;

  /// 通知类型，如 `confirmation_required` / `sandbox_suppressed`。
  final String kind;

  /// 展示层级：`info` / `warning` / `critical`。未知值按 `info` 处理。
  final String severity;

  final String title;
  final String body;

  /// 结构化事实（值一律是字符串）。确认卡会带
  /// `confirmation_id` / `group_id` / `turn_id` / `expires_at`。
  ///
  /// 服务端把它存在 `data_json` 里，**不保证格式**：`expires_at` 解析失败必须
  /// 降级为 null，不能抛。
  final Map<String, String> data;

  /// 所属 group（可空）。深链优先用它。
  final String? groupId;

  final DateTime createdAt;
  final DateTime? updatedAt;

  /// 已读时刻。非空即已读。
  ///
  /// **用户级、跨设备共享**：一端 ack 全端已读（服务端 `owner_notices.read_at`
  /// 是单列）。这与「这台设备弹过没弹过」（本地 receipts）是两件事。
  final DateTime? readAt;

  bool get isRead => readAt != null;

  /// 服务端会复用 ID 覆盖同群的终态；只按 ID 判重会永久吞掉后续结果。
  String get revision =>
      '${(updatedAt ?? createdAt).toUtc().toIso8601String()}:${data['turn_id'] ?? ''}';

  /// 通知是历史事实，确认卡失效只改变展示，不删除通知。
  String displayBody(DateTime now) =>
      kind == 'confirmation_required' && isCardExpiredAt(now)
      ? '$body（已失效，仅作记录）'
      : body;

  String get route => deepLinkGroupId == null
      ? '/settings'
      : '/chat/${Uri.encodeComponent(deepLinkGroupId!)}';

  /// 卡片失效时刻（只有确认卡类通知才有）。
  ///
  /// 注意语义：**通知本身不过期**，过期的是卡片。过期后仍应展示这条通知，
  /// 只是把「去确认」降级为「已失效」。
  DateTime? get cardExpiresAt => _parseDataDate(data['expires_at']);

  /// 卡片是否已失效（无 `expires_at` 时视为「不适用」，返回 false）。
  bool isCardExpiredAt(DateTime now) {
    final expiry = cardExpiresAt;
    return expiry != null && !expiry.isAfter(now);
  }

  /// 深链目标 group：`data.group_id` 优先，退回顶层 `group_id`。
  String? get deepLinkGroupId {
    final fromData = data['group_id'];
    if (fromData != null && fromData.trim().isNotEmpty) return fromData.trim();
    final top = groupId;
    if (top != null && top.trim().isNotEmpty) return top.trim();
    return null;
  }

  /// 关联的确认卡 id（非确认卡通知为 null）。
  String? get confirmationId {
    final v = data['confirmation_id'];
    return (v != null && v.trim().isNotEmpty) ? v : null;
  }

  factory Notice.fromJson(Map<String, dynamic> json) {
    return Notice(
      id: (json['id'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? '',
      severity: _severity(json['severity']),
      title: (json['title'] as String?) ?? '',
      body: (json['body'] as String?) ?? '',
      data: _stringMap(json['data']),
      groupId: _nonEmpty(json['group_id']),
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      updatedAt: _date(json['updated_at']),
      readAt: _date(json['read_at']),
    );
  }

  static String _severity(Object? v) {
    final s = (v as String?)?.trim();
    if (s == 'warning' || s == 'critical' || s == 'info') return s!;
    // 未知层级降级为 info：宁可少一点视觉强调，也不要因为服务端加字段而崩。
    return 'info';
  }

  static Map<String, String> _stringMap(Object? v) {
    if (v is! Map) return const {};
    final out = <String, String>{};
    for (final entry in v.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final value = entry.value;
      if (value == null) continue;
      out[key] = value is String ? value : value.toString();
    }
    return out;
  }

  static String? _nonEmpty(Object? v) {
    if (v is! String) return null;
    return v.trim().isEmpty ? null : v;
  }

  static DateTime? _date(Object? v) {
    if (v is! String || v.trim().isEmpty) return null;
    return DateTime.tryParse(v)?.toLocal();
  }

  static DateTime? _parseDataDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    // data_json 是服务端自由字段，格式不保证；解析失败返回 null 而不是抛。
    return DateTime.tryParse(raw)?.toLocal();
  }
}
