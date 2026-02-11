import 'package:black_square/main.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('App loads with Black Square title', (WidgetTester tester) async {
    final chatService = ChatService();
    await chatService.initialize();

    await tester.pumpWidget(
      Provider<ChatService>.value(
        value: chatService,
        child: const BlackSquareApp(),
      ),
    );

    expect(find.text('Black Square'), findsOneWidget);
  });
}
