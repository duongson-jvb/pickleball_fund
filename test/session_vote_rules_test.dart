import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';

void main() {
  group('Session: hạn vote & giới hạn', () {
    test('hạn vote mặc định = giờ chơi; đặt riêng thì dùng giá trị đó', () {
      final start = DateTime(2026, 11, 1, 18);
      final s = Session(id: 's', title: '', date: start, createdAt: DateTime(2026, 10, 30));
      expect(s.effectiveVoteDeadline, start);
      final s2 = s.copyWith(voteDeadline: DateTime(2026, 11, 1, 12));
      expect(s2.effectiveVoteDeadline, DateTime(2026, 11, 1, 12));
      expect(s2.copyWith(clearVoteDeadline: true).voteDeadline, isNull);
    });

    test('isFull theo số vote đi và maxPlayers', () {
      final s = Session(
        id: 's', title: '', date: DateTime(2027), createdAt: DateTime(2026),
        maxPlayers: 2, votes: const {'a': true, 'b': true, 'c': false},
      );
      expect(s.isFull, isTrue);
      expect(s.copyWith(clearMaxPlayers: true).isFull, isFalse);
      expect(s.copyWith(maxPlayers: 3).isFull, isFalse);
    });

    test('chốt danh sách khi quá giới hạn ưu tiên người vote trước', () {
      final s = Session(
        id: 's1', title: 'B', date: DateTime(2026, 10, 25, 18), maxPlayers: 2,
        votes: const {'p3': true, 'p1': true, 'p2': true, 'p4': false},
        voteTimes: {
          'p3': DateTime(2026, 10, 21, 10),
          'p1': DateTime(2026, 10, 21, 8),
          'p2': DateTime(2026, 10, 21, 9),
        },
        createdAt: DateTime(2026, 10, 20),
      );
      expect(s.votedYesByTime, ['p1', 'p2', 'p3']);
      expect(s.playersForClosing(), ['p1', 'p2']);
      expect(s.copyWith(playerIds: ['p3']).playersForClosing(), ['p3', 'p1']);
      final noTimes = s.copyWith(voteTimes: {'p2': DateTime(2026, 10, 21)});
      expect(noTimes.votedYesByTime.first, 'p2');
    });
  });
}
