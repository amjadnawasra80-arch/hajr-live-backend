import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;

  @override
  String toString() => message;
}

/// Thin typed client for the HAJR LIVE Go backend.
class ApiClient {
  ApiClient({http.Client? httpClient, String? baseUrl})
    : _http = httpClient ?? http.Client(),
      _base = baseUrl ?? AppConfig.apiBase;

  final http.Client _http;
  final String _base;

  /// Set after login; sent as `Authorization: Bearer <jwt>`.
  String? token;

  /// Called when the server answers 401 for an authenticated call (expired/invalid token).
  void Function()? onUnauthorized;

  static const _timeout = Duration(seconds: 15);

  Map<String, String> _headers({String? idempotencyKey, bool auth = true}) => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (auth && token != null) 'Authorization': 'Bearer $token',
    'Idempotency-Key': ?idempotencyKey,
  };

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? body,
    String? idempotencyKey,
    bool auth = true,
  }) async {
    final uri = Uri.parse('$_base$path');
    final headers = _headers(idempotencyKey: idempotencyKey, auth: auth);
    http.Response res;
    try {
      res =
          await (method == 'GET'
                  ? _http.get(uri, headers: headers)
                  : _http.post(
                      uri,
                      headers: headers,
                      body: jsonEncode(body ?? {}),
                    ))
              .timeout(_timeout);
    } on TimeoutException {
      throw ApiException(0, 'The server took too long to respond.');
    } catch (_) {
      throw ApiException(0, 'Cannot reach the server at $_base.');
    }

    Map<String, dynamic> json = {};
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // Non-JSON body; fall through to status handling.
    }

    if (res.statusCode >= 200 && res.statusCode < 300) return json;

    final message =
        (json['error'] as String?) ??
        'Request failed (HTTP ${res.statusCode}).';
    if (res.statusCode == 401 && auth) onUnauthorized?.call();
    throw ApiException(res.statusCode, message);
  }

  /// POST /api/login (mock login: backend must run with MOCK_LOGIN_ENABLED=true).
  Future<Session> login(String phoneNumber) async {
    final j = await _send(
      'POST',
      '/api/login',
      body: {'phone_number': phoneNumber},
      auth: false,
    );
    return Session(
      token: j['token'] as String,
      userId: j['user_id'] as String,
      isAdmin: j['is_admin'] == true,
      expiresAt: DateTime.parse(j['expires_at'] as String),
    );
  }

  /// GET /api/wallet
  Future<Wallet> wallet() async =>
      Wallet.fromJson(await _send('GET', '/api/wallet'));

  /// POST /api/gift. Reuse the same [idempotencyKey] when retrying the same gift.
  Future<GiftReceipt> sendGift({
    required String receiverId,
    required CoinType coinType,
    required int amount,
    required String idempotencyKey,
  }) async {
    final j = await _send(
      'POST',
      '/api/gift',
      idempotencyKey: idempotencyKey,
      body: {
        'receiver_id': receiverId,
        'coin_type': coinType.apiValue,
        'amount': amount,
      },
    );
    return GiftReceipt.fromJson(j);
  }

  /// POST /api/topup (admin only on the backend).
  Future<void> topUp({
    required String userId,
    required int fiatAmountMinor,
    required String fiatCurrency,
    required int coins,
    required String provider,
    required String providerTxnId,
  }) async {
    await _send(
      'POST',
      '/api/topup',
      idempotencyKey: providerTxnId.length == 36 ? providerTxnId : null,
      body: {
        'user_id': userId,
        'fiat_amount': fiatAmountMinor,
        'fiat_currency': fiatCurrency,
        'real_coins_minted': coins,
        'payment_provider': provider,
        'provider_txn_id': providerTxnId,
      },
    );
  }

  void close() => _http.close();
}
