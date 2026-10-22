import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'screens/team_gate_screen.dart';
import 'services/auth_service.dart';
import 'services/team_repository.dart';
import 'services/team_store.dart';

const _prefTeamId = 'teamId';

final _messengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await initializeDateFormatting('vi_VN');
  final auth = AuthService();
  try {
    // Đăng nhập ẩn danh để xem & vote (Firestore rules yêu cầu có auth khi ghi).
    await auth.ensureSignedIn();
  } catch (_) {
    // Không có mạng / chưa bật Auth: vẫn vào app để xem, báo lỗi khi ghi.
  }
  final prefs = await SharedPreferences.getInstance();

  // Lỗi "permission-denied" (chưa mở khoá quản trị) → báo gọn thay vì im lặng.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _reportIfPermission(details.exception);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _reportIfPermission(error);
    return true;
  };

  runApp(PickleballFundApp(auth: auth, initialTeamId: prefs.getString(_prefTeamId)));
}

void _reportIfPermission(Object error) {
  final s = error.toString();
  if (s.contains('permission-denied') || s.contains('PERMISSION_DENIED')) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Cần mã bảo mật quản trị để sửa. Bấm biểu tượng ổ khoá ở Tổng quan.'),
      ));
  }
}

class PickleballFundApp extends StatefulWidget {
  const PickleballFundApp({super.key, required this.auth, this.initialTeamId});
  final AuthService auth;
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
    if (_teamId != null) {
      _store = TeamStore(TeamRepository(_teamId!), auth: widget.auth);
    }
  }

  Future<void> _joinTeam(String teamId, String teamName) async {
    await widget.auth.ensureSignedIn();
    final repo = TeamRepository(teamId);
    await repo.ensureTeam(teamName);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefTeamId, teamId);
    _store?.dispose();
    setState(() {
      _teamId = teamId;
      _store = TeamStore(repo, auth: widget.auth);
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
    // TeamScope phải nằm TRÊN MaterialApp (tức trên Navigator) để mọi màn hình
    // mở bằng Navigator.push cũng đọc được store.
    final app = MaterialApp(
      title: 'Quỹ Pickleball',
      scaffoldMessengerKey: _messengerKey,
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
          : HomeScreen(teamId: _teamId!, onLeaveTeam: _leaveTeam),
    );
    if (_store == null) return app;
    return TeamScope(store: _store!, child: app);
  }
}
