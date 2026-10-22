// Người đính kèm khi vote: "2" = đi kèm 1 người; tiền sân / nước của người
// đính kèm trừ vào người vote; giới hạn số người tính cả đính kèm.
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/settlement.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

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
      expect(s.companionsForClosing(ids), {'a': 1},
          reason: 'a giữ 1 đính kèm (4 chỗ: a+1, b, c); c không còn chỗ cho đính kèm');
    });

    test('tên và id người đính kèm', () {
      expect(Session.companionId('p1', 2), 'p1#2');
      expect(Session.isCompanionId('p1#2'), isTrue);
      expect(Session.isCompanionId('p1'), isFalse);
      expect(Session.hostOf('p1#2'), 'p1');
      expect(Session.companionIndex('p1#2'), 2);
    });
  });
}
