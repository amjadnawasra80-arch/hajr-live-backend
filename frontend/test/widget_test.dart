import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hajr_live/models.dart';
import 'package:hajr_live/screens/login_screen.dart';
import 'package:hajr_live/services/api_client.dart';
import 'package:hajr_live/services/session_store.dart';

void main() {
  group('LiveEvent.parse', () {
    test('chat', () {
      final e = LiveEvent.parse({
        'type': 'chat',
        'from': 'u1',
        'data': {'text': 'hello'},
        'ts': '2026-10-12T00:50:00Z',
      });
      expect(e, isA<ChatEvent>());
      expect((e as ChatEvent).text, 'hello');
    });

    test('gift', () {
      final e = LiveEvent.parse({
        'type': 'gift',
        'from': 'sender',
        'data': {
          'transaction_id': 't1',
          'receiver_id': 'r1',
          'coin_type': 'promo_coins',
          'amount': 100,
          'net_amount': 75,
        },
        'ts': '2026-10-12T00:50:00Z',
      });
      expect(e, isA<GiftEvent>());
      final g = e as GiftEvent;
      expect(g.amount, 100);
      expect(g.coinType, CoinType.promo);
    });

    test('malformed frames are ignored', () {
      expect(LiveEvent.parse({'type': 'chat', 'data': {}}), isNull);
      expect(LiveEvent.parse({'type': 'gift', 'data': 'x'}), isNull);
      expect(LiveEvent.parse({'type': 'nope'}), isNull);
    });
  });

  test('formatCoins', () {
    expect(formatCoins(0), '0');
    expect(formatCoins(999), '999');
    expect(formatCoins(1000), '1,000');
    expect(formatCoins(1234567), '1,234,567');
    expect(formatCoins(-5000), '-5,000');
  });

  test('newUuidV4 has v4 shape and is unique', () {
    final re = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    final a = newUuidV4();
    expect(re.hasMatch(a), isTrue);
    expect(newUuidV4(), isNot(a));
  });

  testWidgets('login screen validates phone number before calling the API', (
    tester,
  ) async {
    final store = SessionStore(ApiClient());
    await tester.pumpWidget(MaterialApp(home: LoginScreen(store: store)));

    expect(find.text('HAJR LIVE'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), '12345');
    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.textContaining('international format'), findsOneWidget);
    expect(store.isLoggedIn, isFalse);
  });
}
