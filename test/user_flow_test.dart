// Kiểm thử theo hành trình người dùng thật: bấm đúng các nút trên giao diện
// (không gọi thẳng repository) để chắc rằng tính năng chạy đúng từ đầu tới cuối.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/screens/expenses/expense_form_screen.dart';
import 'package:pickleball_fund/screens/fund/deposit_screen.dart';
import 'package:pickleball_fund/screens/players/player_detail_screen.dart';
import 'package:pickleball_fund/screens/sessions/session_detail_screen.dart';
import 'package:pickleball_fund/services/team_repository.dart';
import 'package:pickleball_fund/services/team_store.dart';

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

Future<TeamStore> bootStore() async {
  final db = FakeFirebaseFirestore();
  final repo = TeamRepository('flow-team', firestore: db);
  await repo.ensureTeam('Flow');
  final store = TeamStore(repo);
  await Future<void>.delayed(const Duration(milliseconds: 60));
  return store;
}

/// Cho Firestore giả lập (chạy ở thời gian thật) kịp phát stream, rồi vẽ lại.
/// Không dùng pumpAndSettle vì màn hình có vòng quay chờ chạy mãi.
Future<void> idle(WidgetTester t, {int rounds = 5}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUpAll(() => initializeDateFormatting('vi_VN'));

  testWidgets('Nộp quỹ cho một người qua màn hình Nộp quỹ', (t) async {
    late TeamStore store;
    late String an;
    await t.runAsync(() async {
      store = await bootStore();
      await store.repo.addPlayer('An');
      await store.repo.addPlayer('Bình');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      an = store.players.firstWhere((p) => p.name == 'An').id;
    });

    await t.pumpWidget(wrap(store, DepositScreen(initialPlayerId: an)));
    await idle(t);

    await t.enterText(find.widgetWithText(TextFormField, 'Số tiền'), '200k');
    await idle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Cập nhật quỹ'));
    await idle(t);

    expect(store.balanceOf(an), 200000);
    expect(store.ledger.single.type, LedgerType.deposit);
    store.dispose();
  });

  testWidgets('Nộp quỹ cho tất cả chia đều theo đầu người', (t) async {
    late TeamStore store;
    await t.runAsync(() async {
      store = await bootStore();
      for (final n in ['An', 'Bình', 'Cường']) {
        await store.repo.addPlayer(n);
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });

    await t.pumpWidget(wrap(store, const DepositScreen()));
    await idle(t);
    await t.tap(find.text('Tất cả (chia đều)'));
    await idle(t);
    await t.enterText(find.widgetWithText(TextFormField, 'Số tiền'), '100000');
    await idle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Cập nhật quỹ'));
    await idle(t);

    final b = store.balances;
    expect(b.values.fold<int>(0, (a, x) => a + x), 100000,
        reason: 'tổng tiền chia ra phải đúng bằng số đã nộp');
    expect(b.values.toList()..sort(), [33333, 33333, 33334]);
    store.dispose();
  });

  testWidgets('Buổi chơi: vote → chốt danh sách → tiền sân chia đều', (t) async {
    late TeamStore store;
    late String sid;
    await t.runAsync(() async {
      store = await bootStore();
      await store.repo.addPlayer('An');
      await store.repo.addPlayer('Bình');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      sid = await store.repo.createSession(Session(
        id: '',
        title: 'Thứ 7',
        date: DateTime.now().add(const Duration(days: 1)),
        courtFee: 300000,
        createdByName: 'An',
        createdAt: DateTime.now(),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });

    await t.pumpWidget(wrap(store, SessionDetailScreen(sessionId: sid)));
    await idle(t);

    await t.tap(find.widgetWithText(CheckboxListTile, 'An'));
    await idle(t);
    await t.tap(find.widgetWithText(CheckboxListTile, 'Bình'));
    await idle(t);
    expect(store.sessions.first.votedYes.length, 2,
        reason: 'tick trong tab Vote phải ghi được vote');

    await t.tap(find.widgetWithText(FilledButton, 'Chốt danh sách'));
    await idle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Chốt'));
    await idle(t);

    final s = store.sessions.first;
    expect(s.status, SessionStatus.closed);
    expect(s.playerIds.length, 2);
    expect(s.settlement.courtPerPlayer.values.fold<int>(0, (a, x) => a + x), 300000);
    expect(store.balances.values.fold<int>(0, (a, x) => a + x), -300000);
    store.dispose();
  });

  testWidgets('Buổi chơi: thêm nước bằng nút +1 thì trừ đúng tiền', (t) async {
    late TeamStore store;
    late String sid;
    late String an;
    await t.runAsync(() async {
      store = await bootStore();
      await store.repo.addPlayer('An');
      await store.repo.addDrinkType('Revive', 15000, code: 1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      an = store.players.first.id;
      sid = await store.repo.createSession(Session(
        id: '',
        title: 'Buổi nước',
        date: DateTime.now(),
        playerIds: [an],
        status: SessionStatus.closed,
        createdByName: 'An',
        createdAt: DateTime.now(),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });

    await t.pumpWidget(wrap(store, SessionDetailScreen(sessionId: sid)));
    await idle(t);
    await t.tap(find.text('Nước'));
    await idle(t, rounds: 15); // chờ hiệu ứng chuyển tab xong

    await t.tap(find.byIcon(Icons.add_circle_outline).first);
    await idle(t);
    await t.tap(find.byIcon(Icons.add_circle_outline).first);
    await idle(t);

    expect(store.sessions.first.drinkQty(an, store.drinkTypes.first.id), 2);
    expect(store.balanceOf(an), -30000);

    await t.tap(find.byIcon(Icons.remove_circle_outline).first);
    await idle(t);
    expect(store.balanceOf(an), -15000, reason: 'bớt một chai phải hoàn lại tiền');
    store.dispose();
  });

  testWidgets('Chi phí chung: quỹ chung trả trước, phần thiếu chia đều', (t) async {
    late TeamStore store;
    await t.runAsync(() async {
      store = await bootStore();
      await store.repo.addPlayer('An');
      await store.repo.addPlayer('Bình');
      await store.repo.addCommonFund(amount: 50000);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });

    await t.pumpWidget(wrap(store, const ExpenseFormScreen()));
    await idle(t);
    await t.enterText(
        find.widgetWithText(TextFormField, 'Tên chi phí * (VD: Mua bóng)'), 'Mua bóng');
    await t.enterText(find.widgetWithText(TextFormField, 'Số tiền'), '90000');
    await idle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Lưu & trừ quỹ'));
    await idle(t);

    final e = store.expenses.single;
    expect(e.commonUsed, 50000);
    expect(e.perPlayer.values.fold<int>(0, (a, x) => a + x), 40000);
    expect(store.commonFund, 0);
    store.dispose();
  });

  testWidgets('Xoá người chơi thì xoá cả giao dịch của người đó', (t) async {
    late TeamStore store;
    late String anId;
    await t.runAsync(() async {
      store = await bootStore();
      await store.repo.addPlayer('An');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      anId = store.players.single.id;
      await store.repo.deposit(playerId: anId, amount: 100000);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });

    await t.pumpWidget(wrap(store, PlayerDetailScreen(playerId: anId)));
    await idle(t);
    await t.tap(find.byIcon(Icons.more_vert).first);
    await idle(t, rounds: 10);
    await t.tap(find.text('Xoá người chơi'));
    await idle(t, rounds: 10);
    await t.tap(find.widgetWithText(FilledButton, 'Xoá'));
    await idle(t, rounds: 10);

    expect(store.players, isEmpty);
    expect(store.ledger, isEmpty);
    store.dispose();
  });
}
