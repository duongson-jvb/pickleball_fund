// Đếm suất phải nhất quán giữa vote, danh sách chơi và tổng kết.
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/settlement.dart';

Session _s({
  Map<String, bool> votes = const {},
  List<String> players = const [],
  Map<String, int> comp = const {},
  int khach = 0,
  int? max,
  SessionStatus status = SessionStatus.voting,
}) =>
    Session(
      id: 's', title: 'B', date: DateTime(2026, 11, 1, 18),
      courtFee: 400000, votes: votes, playerIds: players, companions: comp,
      guestCount: khach, maxPlayers: max, status: status,
      voteTimes: {
        for (var i = 0; i < votes.length; i++)
          votes.keys.elementAt(i): DateTime(2026, 10, 30, 10, i),
      },
      createdAt: DateTime(2026, 10, 29),
    );

void main() {
  group('seatsTaken', () {
    test('đang vote: đếm người vote đi và người đính kèm', () {
      expect(_s(votes: {'An': true, 'Binh': true}, comp: {'An': 1}).seatsTaken, 3);
    });

    test('người vote "không đi" không chiếm chỗ', () {
      expect(_s(votes: {'An': true, 'Binh': false}).seatsTaken, 1);
    });

    test('người quản lý thêm thẳng vào danh sách CŨNG chiếm chỗ', () {
      // Trước đây chỉ đếm votes nên Cường không chiếm suất nào.
      final s = _s(votes: {'An': true}, players: ['An', 'Cuong'], comp: {'An': 1});
      expect(s.seatsTaken, 3, reason: 'An + 1 đính kèm + Cường');
      expect(s.addedWithoutVote, ['Cuong']);
    });

    test('không đếm trùng khi người đó vừa vote vừa ở trong danh sách', () {
      expect(_s(votes: {'An': true}, players: ['An'], comp: {'An': 1}).seatsTaken, 2);
    });

    test('buổi đã chốt: chỉ đếm danh sách chơi, không đếm người đã bị cắt', () {
      // An kèm 2, Bình và Cường cũng vote, nhưng chốt giới hạn 3 chỉ còn An.
      final s = _s(
        votes: {'An': true, 'Binh': true, 'Cuong': true},
        players: ['An'], comp: {'An': 2}, max: 3,
        status: SessionStatus.closed,
      );
      expect(s.seatsTaken, 3, reason: 'đúng bằng danh sách thật, không phải 5');
      expect(s.isFull, isTrue);
    });
  });

  group('khớp với số tính tiền', () {
    test('đã chốt thì suất giữ chỗ = số người tính tiền (không có khách)', () {
      for (final comp in [0, 1, 3]) {
        final s = _s(
          votes: {'An': true, 'Binh': true},
          players: ['An', 'Binh'],
          comp: comp == 0 ? const {} : {'An': comp},
          status: SessionStatus.closed,
        );
        final st = Settlement.computeSession(session: s, commonFundAvailable: 0);
        expect(s.seatsTaken, st.participants, reason: 'kèm=$comp');
      }
    });

    test('có khách thì số tính tiền = suất giữ chỗ + khách', () {
      final s = _s(
        votes: {'An': true}, players: ['An'], comp: {'An': 1}, khach: 2,
        status: SessionStatus.closed,
      );
      final st = Settlement.computeSession(session: s, commonFundAvailable: 0);
      expect(st.participants, s.seatsTaken + s.guestCount);
      // Dòng hiển thị trên màn hình phải cộng đúng: người chơi + đính kèm + khách.
      expect(s.playerIds.length + s.totalCompanions + s.guestCount, st.participants);
    });
  });

  group('seatHolders', () {
    test('cùng thứ tự ưu tiên với lúc cắt: danh sách chơi trước, rồi vote theo giờ', () {
      final s = _s(votes: {'An': true, 'Binh': true}, players: ['Cuong']);
      expect(s.seatHolders, ['Cuong', 'An', 'Binh']);
      expect(s.seatHolders, s.playersForClosing(),
          reason: 'danh sách bot báo phải trùng thứ tự sẽ giữ khi hết chỗ');
    });

    test('người vote "không đi" nhưng vẫn trong danh sách thì vẫn giữ chỗ', () {
      // Quản lý đưa vào danh sách là họ có chơi, vote cũ coi như đã cũ.
      final s = _s(votes: {'An': false}, players: ['An', 'Binh']);
      expect(s.seatHolders, ['An', 'Binh']);
      expect(s.seatsTaken, 2);
    });

    test('ai trong danh sách chơi cũng là người giữ chỗ (nên không bị chặn vote)', () {
      final s = _s(votes: {'Binh': true}, players: ['An'], max: 2);
      expect(s.seatHolders.contains('An'), isTrue);
      expect(s.seatsTaken, 2);
      expect(s.isFull, isTrue, reason: 'An + Bình đã kín 2 suất');
    });

    test('buổi đã chốt thì đúng bằng danh sách chơi', () {
      final s = _s(
        votes: {'An': true, 'Binh': true}, players: ['An'],
        status: SessionStatus.closed,
      );
      expect(s.seatHolders, ['An']);
    });
  });
}
