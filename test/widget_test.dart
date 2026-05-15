import 'package:benchvault/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('BenchVault shell renders', (tester) async {
    await tester.pumpWidget(const BenchVaultApp());
    expect(find.text('BenchVault'), findsOneWidget);
    expect(find.text('Backup All'), findsOneWidget);
  });
}
