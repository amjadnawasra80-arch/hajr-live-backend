import 'dart:math';

class Session {
  Session({
    required this.token,
    required this.userId,
    required this.isAdmin,
    required this.expiresAt,
  });

  final String token;
  final String userId;
  final bool isAdmin;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class Wallet {
  const Wallet({required this.realCoins, required this.promoCoins});

  final int realCoins;
  final int promoCoins;

  factory Wallet.fromJson(Map<String, dynamic> j) => Wallet(
    realCoins: (j['real_coins'] as num).toInt(),
    promoCoins: (j['promo_coins'] as num).toInt(),
  );
}

enum CoinType {
  real('real_coins', 'Real coins'),
  promo('promo_coins', 'Promo coins');

  const CoinType(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static CoinType parse(String? v) => CoinType.values.firstWhere(
    (c) => c.apiValue == v,
    orElse: () => CoinType.real,
  );
}

class GiftReceipt {
  const GiftReceipt({
    required this.transactionId,
    required this.grossAmount,
    required this.platformFee,
    required this.netAmount,
    required this.replayed,
  });

  final String transactionId;
  final int grossAmount;
  final int platformFee;
  final int netAmount;
  final bool replayed;

  factory GiftReceipt.fromJson(Map<String, dynamic> j) => GiftReceipt(
    transactionId: j['transaction_id'] as String,
    grossAmount: (j['gross_amount'] as num).toInt(),
    platformFee: (j['platform_fee'] as num).toInt(),
    netAmount: (j['net_amount'] as num).toInt(),
    replayed: j['replayed'] == true,
  );
}

/// A frame pushed by the server over the WebSocket.
sealed class LiveEvent {
  const LiveEvent(this.from, this.at);
  final String from;
  final DateTime at;

  static LiveEvent? parse(Map<String, dynamic> j) {
    final from = (j['from'] as String?) ?? '';
    final at =
        DateTime.tryParse((j['ts'] as String?) ?? '')?.toLocal() ??
        DateTime.now();
    final data = j['data'];
    switch (j['type']) {
      case 'chat':
        final text = data is Map ? data['text'] : null;
        if (text is! String || text.trim().isEmpty) return null;
        return ChatEvent(from, at, text);
      case 'gift':
        if (data is! Map) return null;
        final amount = data['amount'];
        final receiver = data['receiver_id'];
        final txn = data['transaction_id'];
        if (amount is! num || receiver is! String || txn is! String) {
          return null;
        }
        return GiftEvent(
          from,
          at,
          transactionId: txn,
          receiverId: receiver,
          coinType: CoinType.parse(data['coin_type'] as String?),
          amount: amount.toInt(),
        );
      case 'error':
        final msg = data is Map ? data['message'] : null;
        return SystemEvent(from, at, msg is String ? msg : 'Server error');
      default:
        return null;
    }
  }
}

class ChatEvent extends LiveEvent {
  const ChatEvent(super.from, super.at, this.text);
  final String text;
}

class GiftEvent extends LiveEvent {
  const GiftEvent(
    super.from,
    super.at, {
    required this.transactionId,
    required this.receiverId,
    required this.coinType,
    required this.amount,
  });

  final String transactionId;
  final String receiverId;
  final CoinType coinType;
  final int amount;
}

class SystemEvent extends LiveEvent {
  const SystemEvent(super.from, super.at, this.message);
  final String message;
}

/// RFC 4122 v4 UUID from a secure RNG (used for Idempotency-Key / txn ids).
String newUuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int from, int to) => b
      .sublist(from, to)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

String formatCoins(int n) {
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return n < 0 ? '-$buf' : buf.toString();
}

String shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;
