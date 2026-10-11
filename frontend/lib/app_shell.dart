import 'package:flutter/material.dart';

import 'models.dart';
import 'screens/live_room_screen.dart';
import 'screens/wallet_screen.dart';
import 'services/api_client.dart';
import 'services/live_socket.dart';
import 'services/session_store.dart';

/// Main authenticated area: Live room + Wallet. Owns the single WebSocket connection.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.store, required this.session});

  final SessionStore store;
  final Session session;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final ApiClient _api = widget.store.api;
  late final LiveSocket _socket = LiveSocket(
    tokenProvider: () => widget.store.session?.token,
  );
  final _walletRefresh = ValueNotifier<int>(0);
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _socket.connect();
  }

  @override
  void dispose() {
    _socket.dispose();
    _walletRefresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tab == 0 ? 'HAJR LIVE' : 'Wallet'),
        actions: [
          if (widget.session.isAdmin)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Chip(
                label: Text('ADMIN'),
                visualDensity: VisualDensity.compact,
              ),
            ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout_rounded),
            onPressed: widget.store.logout,
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          LiveRoomScreen(
            api: _api,
            socket: _socket,
            session: widget.session,
            onWalletChanged: () => _walletRefresh.value++,
          ),
          WalletScreen(
            api: _api,
            session: widget.session,
            refresh: _walletRefresh,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.live_tv_outlined),
            selectedIcon: Icon(Icons.live_tv),
            label: 'Live',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet),
            label: 'Wallet',
          ),
        ],
      ),
    );
  }
}
