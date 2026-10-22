import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/team_repository.dart';
import 'package:pickleball_fund/services/team_store.dart';
import 'package:pickleball_fund/services/zalo_bot_service.dart';
import 'package:pickleball_fund/services/zalo_drinks.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

DrinkType _t(String id, String name) => DrinkType(
      id: id, name: name, prices: [DrinkPrice(date: DateTime(2026), price: 10000)]);

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final revive = _t('rv', 'Revive');
  final suoi = _t('su', 'Nước suối');
  final trada = _t('td', 'Trà đá');

  group('ZaloDrinks.looksLikeDrink', () {
    test('nhận ra tin về nước, không nhầm vote', () {
      expect(ZaloDrinks.looksLikeDrink('nước 2', [revive]), isTrue);
      expect(ZaloDrinks.looksLikeDrink('@Bot nước revive 2', [revive], botName: 'Bot'), isTrue);
      expect(ZaloDrinks.looksLikeDrink('revive 2', [revive]), isTrue);
      expect(ZaloDrinks.looksLikeDrink('+1 revive', [revive]), isTrue);
      expect(ZaloDrinks.looksLikeDrink('1', [revive]), isFalse);
      expect(ZaloDrinks.looksLikeDrink('đi', [revive]), isFalse);
      expect(ZaloDrinks.looksLikeDrink('revive ngon', [revive]), isFalse, reason: 'tên không kèm số');
    });
  });

  group('ZaloDrinks.parse', () {
    test('một loại nước: "nước 2" đặt = 2, "+1 nước" cộng 1', () {
      final c = ZaloDrinks.parse('nước 2', [revive]);
      expect(c.isValid, isTrue);
      expect(c.changes.single.drinkTypeId, 'rv');
      expect(c.changes.single.qty, 2);
      expect(c.changes.single.relative, isFalse);
      final c2 = ZaloDrinks.parse('+1 nước', [revive]);
      expect(c2.changes.single.relative, isTrue);
      expect(c2.changes.single.qty, 1);
    });
    test('nhiều loại: cần ghi tên, hiểu cả số trước và sau tên, có dấu phẩy', () {
      final c = ZaloDrinks.parse('nước revive 2, 1 nước suối', [revive, suoi]);
      expect(c.isValid, isTrue);
      expect({for (final x in c.changes) x.drinkTypeId: x.qty}, {'rv': 2, 'su': 1});
      final c2 = ZaloDrinks.parse('nước 2', [revive, suoi]);
      expect(c2.isValid, isFalse);
      expect(c2.error, contains('2 loại'));
    });
    test('tên dài ưu tiên, không dấu, cộng/trừ', () {
      final c = ZaloDrinks.parse('tra da +2, revive -1', [revive, suoi, trada]);
      expect({for (final x in c.changes) x.drinkTypeId: x.qty}, {'td': 2, 'rv': -1});
      expect(c.changes.every((x) => x.relative), isTrue);
    });
    test('không có số → lỗi', () {
      expect(ZaloDrinks.parse('nước', [revive]).isValid, isFalse);
    });
  });

  group('Mã ngắn N1/N2 và danh sách nước', () {
    final rv1 = DrinkType(id: 'rv', name: 'Revive', code: 1,
        prices: [DrinkPrice(date: DateTime(2026), price: 15000)]);
    final su2 = DrinkType(id: 'su', name: 'Nước suối', code: 2,
        prices: [DrinkPrice(date: DateTime(2026), price: 10000)]);

    test('gõ theo mã: "N1 2, n2 1", "+1 #1"', () {
      final c = ZaloDrinks.parse('N1 2, n2 1', [rv1, su2]);
      expect({for (final x in c.changes) x.drinkTypeId: x.qty}, {'rv': 2, 'su': 1});
      final c2 = ZaloDrinks.parse('+1 #1', [rv1, su2]);
      expect(c2.changes.single.drinkTypeId, 'rv');
      expect(c2.changes.single.relative, isTrue);
      expect(ZaloDrinks.looksLikeDrink('N1 2', [rv1, su2]), isTrue);
    });

    test('"@bot nước" là yêu cầu xem danh sách, "nước 2" thì không', () {
      expect(ZaloDrinks.isListRequest('@Bot PickleBall JVB nước', botName: 'Bot PickleBall JVB'), isTrue);
      expect(ZaloDrinks.isListRequest('nước?'), isTrue);
      expect(ZaloDrinks.isListRequest('giá nước'), isTrue);
      expect(ZaloDrinks.isListRequest('nước 2'), isFalse);
      expect(ZaloDrinks.isListRequest('1'), isFalse);
    });

    test('danh sách có mã, tên, giá theo ngày, sắp theo mã', () {
      final text = ZaloDrinks.listText([su2, rv1], on: DateTime(2026, 6, 1));
      expect(text, contains('N1 · Revive · 15.000đ'));
      expect(text, contains('N2 · Nước suối · 10.000đ'));
      expect(text.indexOf('N1'), lessThan(text.indexOf('N2')));
      expect(text, contains('"N1 2"'));
    });
  });

  group('ZaloDrinks.applyChanges / pickSession', () {
    test('áp dụng đặt và cộng, về 0 thì xoá', () {
      var d = ZaloDrinks.applyChanges({}, 'p', [const DrinkChange('rv', 2)]);
      expect(d, {'p': {'rv': 2}});
      d = ZaloDrinks.applyChanges(d, 'p', [const DrinkChange('rv', 1, relative: true)]);
      expect(d['p']!['rv'], 3);
      d = ZaloDrinks.applyChanges(d, 'p', [const DrinkChange('rv', -3, relative: true)]);
      expect(d, isEmpty);
    });
    test('chọn buổi gần nhất mà người đó tham gia', () {
      final now = DateTime(2026, 10, 25, 20);
      final sessions = [
        Session(id: 'old', title: '', date: DateTime(2026, 10, 18, 18), playerIds: const ['p'], createdAt: now),
        Session(id: 'today', title: '', date: DateTime(2026, 10, 25, 18), playerIds: const ['p'], createdAt: now),
        Session(id: 'other', title: '', date: DateTime(2026, 10, 25, 18), playerIds: const ['q'], createdAt: now),
        Session(id: 'next', title: '', date: DateTime(2026, 10, 27, 18), playerIds: const ['p'], createdAt: now),
      ];
      expect(ZaloDrinks.pickSession(sessions, 'p', now)?.id, 'today');
      expect(ZaloDrinks.pickSession(sessions, 'q', now)?.id, 'other');
      expect(ZaloDrinks.pickSession(sessions, 'x', now), isNull);
    });
  });

  group('Lệnh nước qua ZaloVoteSync', () {
    test('ghi nước vào buổi, tính tiền, không bị tính là vote', () async {
      final db = FakeFirebaseFirestore();
      final repo = TeamRepository('t-drink-01', firestore: db);
      await repo.ensureTeam('T');
      await repo.addPlayer('An');
      await repo.addPlayer('Bình');
      await repo.addDrinkType('Revive', 15000);
      await repo.addDrinkType('Nước suối', 10000);
      await repo.updateSettings({'zaloBotToken': 'x:y', 'zaloGroupId': 'g1'});
      final store = TeamStore(repo);
      await settle();
      final an = store.players.firstWhere((p) => p.name == 'An');
      await repo.updatePlayer(an.id, {'zaloId': 'z-an'});
      final now = DateTime.now();
      final sid = await repo.createSession(Session(
        id: '', title: 'Hôm nay', date: now.subtract(const Duration(hours: 1)),
        status: SessionStatus.closed, playerIds: store.players.map((p) => p.id).toList(),
        drinkPrices: store.defaultDrinkPrices(now), createdAt: now.subtract(const Duration(days: 1)),
      ));
      await settle();
      final target = store.sessions.firstWhere((s) => s.id == sid);

      ZaloUpdate msg(String id, String text) => ZaloUpdate(
            eventName: 'message.text.received', messageId: id, fromId: 'z-an', fromName: 'An',
            chatId: 'g1', chatType: 'GROUP', text: text, date: now);

      final r = await ZaloVoteSync.apply(store, [msg('m1', '@Bot nước revive 2, suối 1')], target: target);
      await settle();
      var s = store.sessions.firstWhere((x) => x.id == sid);
      final rv = store.drinkTypes.firstWhere((d) => d.name == 'Revive').id;
      final su = store.drinkTypes.firstWhere((d) => d.name == 'Nước suối').id;
      expect(s.drinks[an.id], {rv: 2, su: 1});
      expect(s.settlement.drinkPerPlayer[an.id], 2 * 15000 + 10000);
      expect(store.balanceOf(an.id), -40000, reason: 'đã trừ tiền nước vào quỹ');
      expect(s.votes, isEmpty, reason: 'không bị hiểu thành vote');
      expect(r.drinkNotes.single, contains('An'));

      // Cộng thêm rồi xoá.
      await ZaloVoteSync.apply(store, [msg('m2', '+1 revive')], target: store.sessions.first);
      await settle();
      s = store.sessions.firstWhere((x) => x.id == sid);
      expect(s.drinks[an.id]![rv], 3);
      await ZaloVoteSync.apply(store, [msg('m3', 'revive 0, suối 0')], target: store.sessions.first);
      await settle();
      s = store.sessions.firstWhere((x) => x.id == sid);
      expect(s.drinks.containsKey(an.id), isFalse);
      expect(store.balanceOf(an.id), 0);
      store.dispose();
    });
  });
}
