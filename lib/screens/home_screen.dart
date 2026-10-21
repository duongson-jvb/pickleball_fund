import 'package:flutter/material.dart';

import '../services/team_store.dart';
import 'dashboard_screen.dart';
import 'expenses/expenses_screen.dart';
import 'players/players_screen.dart';
import 'sessions/sessions_screen.dart';
import 'settings/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.teamId, required this.onLeaveTeam});
  final String teamId;
  final Future<void> Function() onLeaveTeam;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    if (store.error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 48),
                const SizedBox(height: 12),
                Text('Lỗi kết nối Firebase:\n${store.error}',
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton(
                    onPressed: widget.onLeaveTeam,
                    child: const Text('Đổi mã nhóm')),
              ],
            ),
          ),
        ),
      );
    }
    if (!store.isReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final pages = [
      const DashboardScreen(),
      const SessionsScreen(),
      const PlayersScreen(),
      const ExpensesScreen(),
      SettingsScreen(teamId: widget.teamId, onLeaveTeam: widget.onLeaveTeam),
    ];
    final lowCount = store.lowBalancePlayers.length;

    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: lowCount > 0,
              label: Text('$lowCount'),
              child: const Icon(Icons.dashboard_outlined),
            ),
            selectedIcon: const Icon(Icons.dashboard),
            label: 'Tổng quan',
          ),
          const NavigationDestination(
            icon: Icon(Icons.sports_tennis_outlined),
            selectedIcon: Icon(Icons.sports_tennis),
            label: 'Buổi chơi',
          ),
          const NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Người chơi',
          ),
          const NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Chi phí',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Cài đặt',
          ),
        ],
      ),
    );
  }
}
