import 'package:elnla/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ELNLA shell renders', (tester) async {
    await tester.pumpWidget(const ElnlaApp());
    expect(find.text('ELNLA'), findsOneWidget);
    expect(find.text('Backup All'), findsOneWidget);
  });
}
