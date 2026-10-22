// Smoke test: dựng từng màn hình với dữ liệu giả lập để bắt exception khi build,
// và test điều hướng thật (Navigator.push) giống cấu trúc app trong main.dart.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/screens/dashboard_screen.dart';
import 'package:pickleball_fund/screens/expenses/expenses_screen.dart';
import 'package:pickleball_fund/screens/fund/common_fund_screen.dart';
import 'package:pickleball_fund/screens/fund/deposit_screen.dart';
import 'package:pickleball_fund/screens/home_screen.dart';
import 'package:pickleball_fund/screens/players/player_detail_screen.dart';
import 'package:pickleball_fund/screens/players/players_screen.dart';
import 'package:pickleball_fund/screens/sessions/session_detail_screen.dart';
import 'package:pickleball_fund/screens/sessions/sessions_screen.dart';
import 'package:pickleball_fund/screens/settings/drink_types_screen.dart';
import 'package:pickleball_fund/screens/settings/qr_screen.dart';
import 'package:pickleball_fund/screens/settings/settings_screen.dart';
import 'package:pickleball_fund/screens/settings/zalo_bot_screen.dart';
import 'package:pickleball_fund/screens/share/share_screen.dart';
import 'package:pickleball_fund/services/team_repository.dart';
import 'package:pickleball_fund/services/team_store.dart';

/// Giống main.dart: TeamScope nằm TRÊN MaterialApp để route push cũng thấy store.
Widget wrap(TeamStore store, Widget home) => TeamScope(
      store: store,
      child: MaterialApp(
        locale: const Locale('vi', 'VN'),
        supportedLocales: const [Locale('vi', 'VN'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    );

Future<TeamStore> bootStore({bool configured = true}) async {
  final db = FakeFirebaseFirestore();
  final repo = TeamRepository('smoke-team', firestore: db);
  await repo.ensureTeam('Smoke');
  final store = TeamStore(repo);
  if (!configured) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return store;
  }
  await repo.addPlayer('An');
  await repo.addPlayer('Bình');
  await repo.addDrinkType('Revive', 15000);
  await repo.addCommonFund(amount: 100000);
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final playerId = store.players.first.id;
  await repo.deposit(playerId: playerId, amount: 20000);
  final sid = await repo.createSession(Session(
    id: '',
    title: 'Thứ 7',
    date: DateTime(2026, 10, 25, 18),
    courtFee: 300000,
    playerIds: store.players.map((p) => p.id).toList(),
    createdAt: DateTime.now(),
  ));
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await repo.saveAndSettleSession(store.sessions.firstWhere((s) => s.id == sid),
      commonFundExcludingThis: 100000);
  await repo.saveAndSettleExpense(
    Expense(id: '', title: 'Bóng', amount: 90000, date: DateTime.now(), createdAt: DateTime.now()),
    allActivePlayerIds: store.players.map((p) => p.id).toList(),
    commonFundExcludingThis: 0,
  );
  await repo.updateSettings({
    'zaloBotToken': 'a:b',
    'zaloBotName': 'Bot Test',
    // Chế độ webhook để tab Vote không tự long-polling trong test.
    'zaloWebhookUrl': 'https://example.workers.dev/smoke-team',
    'zaloWebhookSecret': 'secret123',
    'zaloWebhookEnabled': true,
    'zaloChats': {
      'g1': {'chatId': 'g1', 'isGroup': true, 'lastFromName': 'An', 'lastText': '@bot', 'lastDate': DateTime.now()},
    },
  });
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return store;
}

void main() {
  late TeamStore store;

  setUpAll(() async {
    await initializeDateFormatting('vi_VN');
  });

  setUp(() async {
    store = await bootStore();
  });

  tearDown(() => store.dispose());

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(wrap(store, screen));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  }

  group('Dựng từng màn hình', () {
    testWidgets('Zalo Bot', (t) => pumpScreen(t, const ZaloBotScreen()));
    testWidgets('Dashboard', (t) => pumpScreen(t, const DashboardScreen()));
    testWidgets('Players', (t) => pumpScreen(t, const PlayersScreen()));
    testWidgets('Player detail',
        (t) => pumpScreen(t, PlayerDetailScreen(playerId: store.players.first.id)));
    testWidgets('Deposit', (t) => pumpScreen(t, const DepositScreen()));
    testWidgets('Common fund', (t) => pumpScreen(t, const CommonFundScreen()));
    testWidgets('Sessions', (t) => pumpScreen(t, const SessionsScreen()));
    testWidgets('Session detail',
        (t) => pumpScreen(t, SessionDetailScreen(sessionId: store.sessions.first.id)));
    testWidgets('Expenses', (t) => pumpScreen(t, const ExpensesScreen()));
    testWidgets('Settings',
        (t) => pumpScreen(t, SettingsScreen(teamId: 'smoke-team', onLeaveTeam: () async {})));
    testWidgets('Drink types', (t) => pumpScreen(t, const DrinkTypesScreen()));
    testWidgets('QR', (t) => pumpScreen(t, const QrScreen()));
    testWidgets('Share', (t) => pumpScreen(t, const ShareScreen()));
  });

  group('Điều hướng thật từ HomeScreen', () {
    testWidgets('Cài đặt → Zalo Bot (nhóm mới, chưa cấu hình)', (tester) async {
      final fresh = await tester.runAsync(() => bootStore(configured: false));
      await tester.pumpWidget(
          wrap(fresh!, HomeScreen(teamId: 'smoke-team', onLeaveTeam: () async {})));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Cài đặt'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Zalo Bot (vote tự động)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zalo Bot (vote tự động)'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Bot Token'), findsOneWidget, reason: 'màn hình Zalo Bot phải hiện nội dung');
      fresh.dispose();
    });

    testWidgets('Tổng quan → Nộp quỹ, QR; Người chơi → chi tiết; Buổi chơi → chi tiết',
        (tester) async {
      await tester.pumpWidget(
          wrap(store, HomeScreen(teamId: 'smoke-team', onLeaveTeam: () async {})));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.widgetWithText(FilledButton, 'Nộp quỹ'));
      await tester.pumpAndSettle();
      expect(find.text('Cập nhật quỹ'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'QR chuyển khoản'));
      await tester.pumpAndSettle();
      expect(find.text('Thông tin tài khoản'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Người chơi'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('An').first);
      await tester.pumpAndSettle();
      expect(find.text('Số dư hiện tại'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Buổi chơi'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thứ 7').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Vote ('), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
