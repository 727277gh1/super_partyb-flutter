/// 用户问题 / 支持工单 DTO（PartyB `/me/support/cases`）。
///
/// 字段沿用 Go API 的 snake_case REST 契约；未知状态保留原值，由展示层选择
/// 通用文案，避免服务端新增状态导致旧客户端解析失败。
class SupportCase {
  const SupportCase({
    required this.caseRef,
    required this.subject,
    required this.description,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.incidentStatus,
  });

  final String caseRef;
  final String subject;
  final String description;
  final String status;
  final String? incidentStatus;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory SupportCase.fromJson(Map<String, dynamic> json) => SupportCase(
    caseRef: _string(json['case_ref']),
    subject: _string(json['subject']),
    description: _string(json['description']),
    status: _string(json['status']),
    incidentStatus: _optionalString(json['incident_status']),
    createdAt: _date(json['created_at']),
    updatedAt: _date(json['updated_at']),
  );

  static String _string(Object? value) => value is String ? value : '';

  static String? _optionalString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static DateTime _date(Object? value) {
    if (value is String) {
      return DateTime.tryParse(value)?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}
