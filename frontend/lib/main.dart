import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'services/session_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SessionStore(ApiClient());
  runApp(HajrLiveApp(store: store));
  store.restore();
}

class HajrLiveApp extends StatelessWidget {
  const HajrLiveApp({super.key, required this.store});

  final SessionStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HAJR LIVE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7B2FF7)),
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (!store.isReady) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final s = store.session;
          if (s == null) return LoginScreen(store: store);
          // Keyed by user so a different login always gets a fresh socket + state.
          return AppShell(key: ValueKey(s.userId), store: store, session: s);
        },
      ),
    );
  }
}
