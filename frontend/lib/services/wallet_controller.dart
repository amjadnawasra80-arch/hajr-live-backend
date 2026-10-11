import 'package:flutter/foundation.dart';

import '../models.dart';
import 'api_client.dart';

/// Holds the current user's balances; shared by the wallet and live-room screens.
class WalletController extends ChangeNotifier {
  WalletController(this._api);

  final ApiClient _api;

  Wallet? wallet;
  bool loading = false;
  String? error;

  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      wallet = await _api.wallet();
    } on ApiException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
