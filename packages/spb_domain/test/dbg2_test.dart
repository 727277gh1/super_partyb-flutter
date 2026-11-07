import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';
void main() {
  test('delayFor(1) 值', () {
    final d = OutboxRetryPolicy().delayFor(1);
    // ignore: avoid_print
    print('delayFor(1)=${d.inMilliseconds}ms');
    expect(d.inMilliseconds, greaterThan(0));
  });
}
