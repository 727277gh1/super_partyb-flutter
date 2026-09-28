import 'package:flutter_test/flutter_test.dart';

import 'package:spb_mobile/app.dart';

void main() {
  testWidgets('移动端能渲染骨架页', (tester) async {
    await tester.pumpWidget(const SpbMobileApp());
    expect(find.text('Super PartyB'), findsOneWidget);
    expect(find.text('移动端骨架已就绪'), findsOneWidget);
  });
}
