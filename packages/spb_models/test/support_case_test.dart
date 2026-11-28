import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

void main() {
  test('parses case fields and tolerates an unknown future status', () {
    final item = SupportCase.fromJson({
      'case_ref': 'case-1',
      'subject': '问题标题',
      'description': '问题描述',
      'status': 'triaged',
      'incident_status': 'recovery_pending',
      'created_at': '2026-11-28T03:00:00Z',
      'updated_at': '2026-11-28T04:00:00Z',
    });

    expect(item.caseRef, 'case-1');
    expect(item.status, 'triaged');
    expect(item.incidentStatus, 'recovery_pending');
    expect(item.updatedAt.toUtc(), DateTime.utc(2026, 11, 28, 4));
  });
}
