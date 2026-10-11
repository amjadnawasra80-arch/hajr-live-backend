import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/api_client.dart';
import '../services/live_socket.dart';

class _GiftBanner {
  _GiftBanner(this.event);
  final GiftEvent event;
}

class LiveRoomScreen extends StatefulWidget {
  const LiveRoomScreen({
    super.key,
    required this.api,
    required this.socket,
    required this.session,
    required this.onWalletChanged,
  });

  final ApiClient api;
  final LiveSocket socket;
  final Session session;
  final VoidCallback onWalletChanged;

  @override
  State<LiveRoomScreen> createState() => _LiveRoomScreenState();
}

class _LiveRoomScreenState extends State<LiveRoomScreen> {
  static const _maxMessages = 200;

  final _messages = <LiveEvent>[]; // chat + system, newest last
  final _banners = <_GiftBanner>[];
  final _seenGifts = <String>{};
  final _input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<LiveEvent>? _evSub;
  StreamSubscription<SocketStatus>? _stSub;
  late SocketStatus _status = widget.socket.currentStatus;

  // Remembered between gifts.
  String _hostId = '';

  @override
  void initState() {
    super.initState();
    _evSub = widget.socket.events.listen(_onEvent);
    _stSub = widget.socket.status.listen((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _evSub?.cancel();
    _stSub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onEvent(LiveEvent e) {
    if (!mounted) return;
    setState(() {
      switch (e) {
        case ChatEvent():
        case SystemEvent():
          _messages.add(e);
          if (_messages.length > _maxMessages) {
            _messages.removeRange(0, _messages.length - _maxMessages);
          }
        case GiftEvent():
          if (!_seenGifts.add(e.transactionId)) return;
          if (_seenGifts.length > 500) _seenGifts.remove(_seenGifts.first);
          _messages.add(e);
          final banner = _GiftBanner(e);
          _banners.add(banner);
          Timer(const Duration(milliseconds: 3800), () {
            if (mounted) setState(() => _banners.remove(banner));
          });
          // Someone gifted me: balance changed.
          if (e.receiverId == widget.session.userId ||
              e.from == widget.session.userId) {
            widget.onWalletChanged();
          }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (text.length > 500) {
      _toast('Messages are limited to 500 characters.');
      return;
    }
    if (!widget.socket.sendChat(text)) {
      _toast('Not connected. Reconnecting…');
      return;
    }
    _input.clear();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String _name(String id) => id == widget.session.userId ? 'You' : shortId(id);

  Future<void> _openGiftSheet() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GiftSheet(
        api: widget.api,
        initialHostId: _hostId,
        onHostChanged: (v) => _hostId = v,
      ),
    );
    if (result != null && mounted) {
      _toast(result);
      widget.onWalletChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        // --- Stage + gift animations ---
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black87,
                      theme.colorScheme.primary.withValues(alpha: 0.7),
                    ],
                  ),
                ),
                child: const Center(
                  child: Icon(
                    Icons.videocam_rounded,
                    size: 64,
                    color: Colors.white24,
                  ),
                ),
              ),
              Positioned(top: 8, left: 8, child: _StatusChip(status: _status)),
              Positioned(
                left: 8,
                bottom: 8,
                right: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final b in _banners)
                      _GiftBannerView(
                        key: ValueKey(b.event.transactionId),
                        event: b.event,
                        senderName: _name(b.event.from),
                        receiverName: _name(b.event.receiverId),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // --- Chat ---
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Text(
                    'Say hello to the room 👋',
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _MessageTile(
                    event: _messages[i],
                    name: _name,
                    me: widget.session.userId,
                  ),
                ),
        ),
        // --- Composer ---
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    maxLength: 500,
                    maxLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Type a message',
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(24)),
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: _send,
                  icon: const Icon(Icons.send_rounded),
                ),
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  tooltip: 'Send a gift',
                  onPressed: _openGiftSheet,
                  icon: const Icon(Icons.card_giftcard_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final SocketStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SocketStatus.connected => ('LIVE', Colors.redAccent),
      SocketStatus.connecting => ('Connecting…', Colors.orange),
      SocketStatus.disconnected => ('Offline', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.event,
    required this.name,
    required this.me,
  });

  final LiveEvent event;
  final String Function(String) name;
  final String me;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (event) {
      case ChatEvent(:final from, :final text):
        final mine = from == me;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${name(from)}  ',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: mine
                        ? theme.colorScheme.primary
                        : theme.colorScheme.secondary,
                  ),
                ),
                TextSpan(text: text),
              ],
            ),
          ),
        );
      case GiftEvent(
        :final from,
        :final receiverId,
        :final amount,
        :final coinType,
      ):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            '🎁 ${name(from)} sent ${formatCoins(amount)} ${coinType == CoinType.promo ? 'promo ' : ''}coins to ${name(receiverId)}',
            style: TextStyle(
              color: Colors.amber.shade800,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      case SystemEvent(:final message):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            message,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        );
    }
  }
}

String _emojiFor(int amount) {
  if (amount >= 500) return '👑';
  if (amount >= 100) return '🚀';
  if (amount >= 10) return '💎';
  return '🌹';
}

/// Slide-in banner with a bouncing emoji that fades out; removed by the parent after ~3.8s.
class _GiftBannerView extends StatefulWidget {
  const _GiftBannerView({
    super.key,
    required this.event,
    required this.senderName,
    required this.receiverName,
  });

  final GiftEvent event;
  final String senderName;
  final String receiverName;

  @override
  State<_GiftBannerView> createState() => _GiftBannerViewState();
}

class _GiftBannerViewState extends State<_GiftBannerView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slide = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.18, curve: Curves.easeOutBack),
    );
    final bounce = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.1, 0.5, curve: Curves.elasticOut),
    );
    final fade = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.82, 1, curve: Curves.easeIn),
    );
    final big = widget.event.amount >= 100;

    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Opacity(
        opacity: 1 - fade.value,
        child: Transform.translate(
          offset: Offset(
            -260 * (1 - slide.value.clamp(0.0, 1.0)),
            -24 * fade.value,
          ),
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.fromLTRB(12, 6, 16, 6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.pink.shade400.withValues(alpha: 0.9),
                  Colors.orange.shade400.withValues(alpha: 0.9),
                ],
              ),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.scale(
                  scale:
                      (big ? 1.6 : 1.2) *
                      (0.4 + 0.6 * bounce.value.clamp(0.0, 1.5)),
                  child: Text(
                    _emojiFor(widget.event.amount),
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    '${widget.senderName} → ${widget.receiverName}  ×${formatCoins(widget.event.amount)}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GiftSheet extends StatefulWidget {
  const _GiftSheet({
    required this.api,
    required this.initialHostId,
    required this.onHostChanged,
  });

  final ApiClient api;
  final String initialHostId;
  final ValueChanged<String> onHostChanged;

  @override
  State<_GiftSheet> createState() => _GiftSheetState();
}

class _GiftSheetState extends State<_GiftSheet> {
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static const _presets = [1, 10, 50, 100, 500];

  late final _host = TextEditingController(text: widget.initialHostId);
  final _custom = TextEditingController();
  CoinType _coin = CoinType.promo;
  int _amount = 10;
  bool _busy = false;
  String? _error;
  Wallet? _wallet;

  // Same key is reused when retrying an identical gift (e.g. after a timeout), so it can never double-charge.
  String? _key;
  String? _keySig;

  @override
  void initState() {
    super.initState();
    widget.api
        .wallet()
        .then((w) {
          if (mounted) setState(() => _wallet = w);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _host.dispose();
    _custom.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final host = _host.text.trim().toLowerCase();
    if (!_uuid.hasMatch(host)) {
      setState(() => _error = 'Enter the host’s user ID (UUID).');
      return;
    }
    if (_amount < 1 || _amount > 1000000000) {
      setState(() => _error = 'Amount must be at least 1.');
      return;
    }
    widget.onHostChanged(host);

    final sig = '$host|${_coin.apiValue}|$_amount';
    if (_keySig != sig) {
      _keySig = sig;
      _key = newUuidV4();
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.sendGift(
        receiverId: host,
        coinType: _coin,
        amount: _amount,
        idempotencyKey: _key!,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        r.replayed
            ? 'Gift already sent.'
            : 'Gift sent! Host receives ${formatCoins(r.netAmount)} (fee ${formatCoins(r.platformFee)}).',
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (e.statusCode) {
          404 => 'That user was not found.',
          422 => 'Not enough ${_coin.label.toLowerCase()}.',
          _ => e.message,
        };
        // A definitive rejection means a fresh attempt may use a fresh key.
        if (e.statusCode >= 400 && e.statusCode < 500) _keySig = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balance = _wallet == null
        ? null
        : (_coin == CoinType.real ? _wallet!.realCoins : _wallet!.promoCoins);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Send a gift', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _host,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Host user ID',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<CoinType>(
              segments: [
                for (final c in CoinType.values)
                  ButtonSegment(value: c, label: Text(c.label)),
              ],
              selected: {_coin},
              onSelectionChanged: _busy
                  ? null
                  : (s) => setState(() => _coin = s.first),
            ),
            if (balance != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Balance: ${formatCoins(balance)}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final p in _presets)
                  ChoiceChip(
                    label: Text('${_emojiFor(p)} ${formatCoins(p)}'),
                    selected: _amount == p && _custom.text.isEmpty,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() {
                            _amount = p;
                            _custom.clear();
                          }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _custom,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Custom amount',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() {
                final n = int.tryParse(v);
                if (n != null) _amount = n;
              }),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _send,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.card_giftcard_rounded),
              label: Text('Send ${formatCoins(_amount)} coins'),
            ),
            const SizedBox(height: 4),
            Text(
              'A 25% platform fee applies; the host receives the remainder.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
