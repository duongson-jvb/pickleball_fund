// Người đính kèm khi vote: "2" = đi kèm 1 người; tiền sân / nước của người
// đính kèm trừ vào người vote; giới hạn số người tính cả đính kèm.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/settlement.dart';
import 'package:pickleball_fund/services/team_repository.dart';
import 'package:pickleball_fund/services/team_store.dart';
import 'package:pickleball_fund/services/zalo_bot_service.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

ZaloUpdate upd(String id, String from, String name, String text, DateTime at) => ZaloUpdate(
      eventName: 'message.text.received', messageId: id, fromId: from, fromName: name,
      chatId: 'g1', chatType: 'GROUP', text: text, date: at);

void main() {
  group('parseVote / parseVoteCount', () {
    test('số suất', () {
      expect(ZaloVoteSync.parseVote('2'), isTrue);
      expect(ZaloVoteSync.parseVote('0'), isFalse);
      expect(ZaloVoteSync.parseVoteCount('1'), 1);
      expect(ZaloVoteSync.parseVoteCount('2'), 2);
      expect(ZaloVoteSync.parseVoteCount('@Bot PickleBall JVB 3', botName: 'Bot PickleBall JVB'), 3);
      expect(ZaloVoteSync.parseVoteCount('đi 2'), 2);
      expect(ZaloVoteSync.parseVoteCount('2 người'), 2);
      expect(ZaloVoteSync.parseVoteCount('đi'), 1);
      expect(ZaloVoteSync.parseVoteCount('không'), isNull);
      expect(ZaloVoteSync.parseVoteCount('0'), isNull);
    });
  });

  group('Settlement với người đính kèm', () {
    test('tiền sân của đính kèm trừ vào người vote; nước của đính kèm gộp vào host', () {
      final s = Session(
        id: 's', title: '', date: DateTime(2027), createdAt: DateTime(2026),
        courtFee: 400000, playerIds: const ['a', 'b'],
        companions: const {'a': 2}, // a + 2 đính kèm, b một mình → 4 suất
        drinkPrices: const {'rv': 10000},
        drinks: const {'a#1': {'rv': 2}, 'b': {'rv': 1}},
      );
      final st = Settlement.computeSession(session: s, commonFundAvailable: 0);
      expect(st.participants, 4);
      expect(st.perHead, 100000);
      expect(st.courtPerPlayer, {'a': 300000, 'b': 100000});
      expect(st.drinkPerPlayer, {'a': 20000, 'b': 10000});
      expect(s.companionIds, ['a#1', 'a#2']);
    });

    test('seatsTaken / isFull / chốt theo chỗ', () {
      final s = Session(
        id: 's', title: '', date: DateTime(2027), createdAt: DateTime(2026), maxPlayers: 4,
        votes: const {'a': true, 'b': true, 'c': true},
        companions: const {'a': 1, 'c': 2},
        voteTimes: {'a': DateTime(2026, 1, 1), 'b': DateTime(2026, 1, 2), 'c': DateTime(2026, 1, 3)},
      );
      expect(s.seatsTaken, 6);
      expect(s.isFull, isTrue);
      final ids = s.playersForClosing();
      expect(ids, ['a', 'b', 'c'], reason: 'c vào được nhưng phải bớt đính kèm');
      expect(s.companionsForClosing(ids), {'a': 1}, reason: 'a giữ 1 đính kèm (4 chỗ: a+1, b, c); c không còn chỗ cho đính kèm');
    });
  });

  group('Vote Zalo kèm người', () {
    test('"2" ghi 1 đính kèm, đổi "1" bỏ đính kèm, giới hạn tính cả đính kèm', () async {
      final db = FakeFirebaseFirestore();
      final repo = TeamRepository('t-comp-01', firestore: db);
      await repo.ensureTeam('T');
      for (final n in ['An', 'Bình', 'Chi']) {
        await repo.addPlayer(n);
      }
      await repo.updateSettings({'zaloBotToken': 'x:y', 'zaloGroupId': 'g1'});
      final store = TeamStore(repo);
      await settle();
      final ids = {for (final p in store.players) p.name: p.id};
      final now = DateTime.now();
      final sid = await repo.createSession(Session(
        id: '', title: 'V', date: now.add(const Duration(hours: 3)), status: SessionStatus.voting,
        maxPlayers: 4, createdAt: now.subtract(const Duration(minutes: 5)),
      ));
      await settle();
      Session cur() => store.sessions.firstWhere((x) => x.id == sid);

      await ZaloVoteSync.apply(store, [
        upd('1', 'z-an', 'An', '2', now),
        upd('2', 'z-binh', 'Bình', '1', now.add(const Duration(seconds: 1))),
      ], target: cur());
      await settle();
      expect(cur().companions, {ids['An']!: 1});
      expect(cur().seatsTaken, 3);

      // Chi xin 2 suất → vượt 4 chỗ (3 + 2) → từ chối; xin 1 suất → được.
      final r = await ZaloVoteSync.apply(store, [upd('3', 'z-chi', 'Chi', '2', now.add(const Duration(seconds: 2)))], target: cur());
      expect(r.fullNames.single, contains('Chi'));
      await ZaloVoteSync.apply(store, [upd('4', 'z-chi', 'Chi', '1', now.add(const Duration(seconds: 3)))], target: cur());
      await settle();
      expect(cur().votes[ids['Chi']!], isTrue);
      expect(cur().seatsTaken, 4);

      // An đổi "1" → bỏ đính kèm.
      await ZaloVoteSync.apply(store, [upd('5', 'z-an', 'An', '1', now.add(const Duration(seconds: 4)))], target: cur());
      await settle();
      expect(cur().companions.containsKey(ids['An']!), isFalse);
      expect(cur().seatsTaken, 3);

      // An xin 3 suất khi chỉ còn 1 chỗ trống → từ chối; xin 2 suất → vừa đủ 4 chỗ.
      final r3 = await ZaloVoteSync.apply(store, [upd('6', 'z-an', 'An', '3', now.add(const Duration(seconds: 5)))], target: cur());
      expect(r3.fullNames.single, contains('An'));
      await ZaloVoteSync.apply(store, [upd('7', 'z-an', 'An', '2', now.add(const Duration(seconds: 6)))], target: cur());
      await settle();
      expect(cur().companionsOf(ids['An']!), 1);
      expect(cur().seatsTaken, 4);

      // Chốt: tiền sân chia theo suất (4 suất), đính kèm tính vào An.
      final s = cur();
      final closingIds = s.playersForClosing();
      await repo.saveAndSettleSession(s.copyWith(
        status: SessionStatus.closed, playerIds: closingIds,
        companions: s.companionsForClosing(closingIds), courtFee: 500000,
      ));
      await settle();
      final done = cur();
      expect(done.playerIds.length, 3);
      expect(done.companionsOf(ids['An']!), 1);
      expect(done.settlement.perHead, 125000);
      expect(done.settlement.courtPerPlayer[ids['An']!], 250000, reason: 'An trả cả suất đính kèm');
      expect(done.settlement.courtPerPlayer[ids['Bình']!], 125000);
      expect(store.balanceOf(ids['An']!), -250000);
      store.dispose();
    });

    test('ghi nước cho người đính kèm qua Zalo trừ vào người vote', () async {
      final db = FakeFirebaseFirestore();
      final repo = TeamRepository('t-comp-02', firestore: db);
      await repo.ensureTeam('T');
      await repo.addPlayer('An');
      await repo.addDrinkType('Revive', 15000, code: 1);
      await repo.updateSettings({'zaloBotToken': 'x:y', 'zaloGroupId': 'g1'});
      final store = TeamStore(repo);
      await settle();
      final an = store.players.single;
      await repo.updatePlayer(an.id, {'zaloId': 'z-an'});
      final now = DateTime.now();
      final sid = await repo.createSession(Session(
        id: '', title: 'B', date: now.subtract(const Duration(hours: 1)), status: SessionStatus.closed,
        playerIds: [an.id], companions: {an.id: 1}, drinkPrices: store.defaultDrinkPrices(now),
        createdAt: now.subtract(const Duration(days: 1)),
      ));
      await settle();
      await ZaloVoteSync.apply(store, [upd('d1', 'z-an', 'An', '@An đính kèm 1 N1 2', now)],
          target: store.sessions.firstWhere((x) => x.id == sid));
      await settle();
      final s = store.sessions.firstWhere((x) => x.id == sid);
      expect(s.drinks['${an.id}#1'], isNotNull);
      expect(s.settlement.drinkPerPlayer[an.id], 30000, reason: 'nước của đính kèm trừ vào An');
      expect(store.balanceOf(an.id), -30000);
      expect(store.playerName('${an.id}#1'), 'An đính kèm 1');
      store.dispose();
    });
  });
}
