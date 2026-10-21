import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'screens/team_gate_screen.dart';
import 'services/team_repository.dart';
import 'services/team_store.dart';

const _prefTeamId = 'teamId';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await initializeDateFormatting('vi_VN');
  final prefs = await SharedPreferences.getInstance();
  runApp(PickleballFundApp(initialTeamId: prefs.getString(_prefTeamId)));
}

class PickleballFundApp extends StatefulWidget {
  const PickleballFundApp({super.key, this.initialTeamId});
  final String? initialTeamId;

  @override
  State<PickleballFundApp> createState() => _PickleballFundAppState();
}

class _PickleballFundAppState extends State<PickleballFundApp> {
  String? _teamId;
  TeamStore? _store;

  @override
  void initState() {
    super.initState();
    _teamId = widget.initialTeamId;
    if (_teamId != null) _store = TeamStore(TeamRepository(_teamId!));
  }

  Future<void> _joinTeam(String teamId, String teamName) async {
    final repo = TeamRepository(teamId);
    await repo.ensureTeam(teamName);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefTeamId, teamId);
    _store?.dispose();
    setState(() {
      _teamId = teamId;
      _store = TeamStore(repo);
    });
  }

  Future<void> _leaveTeam() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefTeamId);
    _store?.dispose();
    setState(() {
      _teamId = null;
      _store = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF00897B));
    return MaterialApp(
      title: 'Quỹ Pickleball',
      debugShowCheckedModeBanner: false,
      locale: const Locale('vi', 'VN'),
      supportedLocales: const [Locale('vi', 'VN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        cardTheme: const CardThemeData(
            margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
      ),
      home: _store == null
          ? TeamGateScreen(onJoin: _joinTeam)
          : TeamScope(
              store: _store!,
              child: HomeScreen(teamId: _teamId!, onLeaveTeam: _leaveTeam),
            ),
    );
  }
}
