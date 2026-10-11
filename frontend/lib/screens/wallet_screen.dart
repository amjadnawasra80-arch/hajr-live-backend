import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/api_client.dart';

class _Pack {
  const _Pack(this.coins, this.priceMinor);
  final int coins;
  final int priceMinor; // USD cents
  String get price => '\$${(priceMinor / 100).toStringAsFixed(2)}';
}

const _packs = [
  _Pack(100, 99),
  _Pack(500, 499),
  _Pack(1000, 999),
  _Pack(5000, 4999),
];

class WalletScreen extends StatefulWidget {
  const WalletScreen({
    super.key,
    required this.api,
    required this.session,
    required this.refresh,
  });

  final ApiClient api;
  final Session session;

  /// Bumped by other screens (e.g. after a gift) to request a reload.
  final ValueListenable<int> refresh;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Wallet? _wallet;
  String? _loadError;
  bool _loading = true;

  final _target = TextEditingController();
  String? _busyPack;
  // One idempotency key per pack until it succeeds, so a retry after a timeout cannot double-credit.
  final Map<int, String> _txnKeys = {};

  @override
  void initState() {
    super.initState();
    _target.text = widget.session.userId;
    widget.refresh.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_load);
    _target.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final w = await widget.api.wallet();
      if (!mounted) return;
      setState(() => _wallet = w);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  Future<void> _topUp(_Pack pack) async {
    final target = _target.text.trim();
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(target)) {
      _toast('Target user ID must be a valid UUID.', error: true);
      return;
    }
    final key = _txnKeys.putIfAbsent(pack.coins, newUuidV4);
    setState(() => _busyPack = key);
    try {
      await widget.api.topUp(
        userId: target,
        fiatAmountMinor: pack.priceMinor,
        fiatCurrency: 'USD',
        coins: pack.coins,
        provider: 'hajr_admin_console',
        providerTxnId: key,
      );
      _txnKeys.remove(pack.coins);
      _toast('Added ${formatCoins(pack.coins)} real coins.');
      await _load();
    } on ApiException catch (e) {
      _toast(
        e.isForbidden
            ? 'Top-ups are restricted to administrator accounts.'
            : e.message,
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busyPack = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = widget.session.isAdmin;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: _BalanceCard(
                  icon: Icons.monetization_on_rounded,
                  label: 'Real coins',
                  value: _wallet?.realCoins,
                  color: Colors.amber.shade700,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _BalanceCard(
                  icon: Icons.card_giftcard_rounded,
                  label: 'Promo coins',
                  value: _wallet?.promoCoins,
                  color: Colors.pink.shade400,
                ),
              ),
            ],
          ),
          if (_loading && _wallet == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_loadError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _loadError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Your user ID'),
              subtitle: SelectableText(widget.session.userId),
              trailing: IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: widget.session.userId),
                  );
                  if (mounted) _toast('User ID copied.');
                },
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('Top up', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          if (!isAdmin)
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Top-ups are restricted to administrator accounts. '
                  'Customer purchases are credited by the payment provider.',
                ),
              ),
            ),
          if (isAdmin) ...[
            TextField(
              controller: _target,
              decoration: const InputDecoration(
                labelText: 'Credit user ID',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (final p in _packs)
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.monetization_on_rounded,
                  color: Colors.amber,
                ),
                title: Text('${formatCoins(p.coins)} coins'),
                subtitle: Text(p.price),
                trailing: FilledButton(
                  onPressed: (!isAdmin || _busyPack != null)
                      ? null
                      : () => _topUp(p),
                  child: _busyPack != null && _busyPack == _txnKeys[p.coins]
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Top up'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final int? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 8),
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              value == null ? '—' : formatCoins(value!),
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}
