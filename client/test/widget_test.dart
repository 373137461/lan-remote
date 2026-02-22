import 'package:flutter_test/flutter_test.dart';
import 'package:lan_remote/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const LanRemoteApp());
    expect(find.text('局域网键鼠遥控器'), findsNothing); // 标题在 AppBar 中
  });
}
