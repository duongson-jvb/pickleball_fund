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

    test('CHƯA chốt: người vote qua Zalo cũng được tính tiền', () {
      // Một danh sách duy nhất: ai đang giữ chỗ thì tính tiền cho người đó,
      // không cần chờ quản lý tích tay vào danh sách chơi.
      final s = _s(votes: {'An': true, 'Binh': true}, players: ['An'], comp: {'Binh': 1});
      final st = Settlement.computeSession(session: s, commonFundAvailable: 0);
      expect(st.participants, 3, reason: 'An + Bình + 1 đính kèm của Bình');
      expect(st.participants, s.seatsTaken);
      expect(st.courtPerPlayer.keys.toSet(), {'An', 'Binh'});
      // Tiền sân của người đính kèm trừ vào người vote → Bình gánh 2 phần
      // (lệch vài đồng vì phần dư của phép chia được rải cho người đầu).
      final an = st.courtPerPlayer['An']!;
      final binh = st.courtPerPlayer['Binh']!;
      expect(an + binh, s.courtFee);
      expect((binh - an * 2).abs() <= 2, isTrue, reason: 'An=$an Bình=$binh');
    });

    test('CHƯA chốt: người vote "không đi" không bị tính tiền', () {
      final s = _s(votes: {'An': true, 'Binh': false});
      final st = Settlement.computeSession(session: s, commonFundAvailable: 0);
      expect(st.participants, 1);
      expect(st.courtPerPlayer.containsKey('Binh'), isFalse);
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

  group('số tiền dự kiến lúc đang vote', () {
    LedgerEntry fund(int amount, {String? refId}) => LedgerEntry(
          id: '', playerId: null, amount: amount,
          type: amount > 0 ? LedgerType.commonIn : LedgerType.commonOut,
          refId: refId, note: '', date: DateTime(2026), createdAt: DateTime(2026),
        );
    Session open(String id, int day, Map<String, bool> votes) => Session(
          id: id, title: id, date: DateTime(2026, 11, day), courtFee: 300000,
          votes: votes, createdAt: DateTime(2026, 10, 1),
        );

    test('tính theo danh sách hiện tại, không theo số đã lưu trong buổi', () {
      final s = open('s', 5, {'An': true, 'Binh': true});
      final st = Settlement.estimate(session: s, sessions: [s], ledger: const []);
      expect(st.participants, 2);
      expect(st.courtPerPlayer, {'An': 150000, 'Binh': 150000});
    });

    test('nhiều buổi cùng mở dùng chung quỹ chung: buổi diễn ra trước dùng trước', () {
      final b1 = open('b1', 3, {'An': true});
      final b2 = open('b2', 6, {'Binh': true});
      final ledger = [fund(400000)];
      expect(Settlement.estimate(session: b1, sessions: [b2, b1], ledger: ledger).commonUsed, 300000);
      expect(Settlement.estimate(session: b2, sessions: [b2, b1], ledger: ledger).commonUsed, 100000,
          reason: 'chỉ còn 100k sau buổi diễn ra trước');
    });

    test('buổi mở lại vote: không tính hai lần phần quỹ chung đã trừ lần chốt trước', () {
      final s = open('s', 5, {'An': true});
      // Lần chốt trước quỹ chung đã chi 300k cho chính buổi này.
      final ledger = [fund(300000), fund(-300000, refId: 's')];
      expect(Settlement.estimate(session: s, sessions: [s], ledger: ledger).commonUsed, 300000);
    });

    test('buổi đã chốt: đúng số đã lưu (đã trừ vào quỹ)', () {
      const saved = SessionSettlement(participants: 7, perHead: 1);
      final s = Session(
        id: 's', title: 's', date: DateTime(2026, 11, 5), status: SessionStatus.closed,
        settlement: saved, createdAt: DateTime(2026, 10, 1),
      );
      expect(Settlement.estimate(session: s, sessions: [s], ledger: const []), same(saved));
    });
  });

  group('seatHolders', () {
    test('cùng thứ tự ưu tiên với lúc cắt: danh sách chơi trước, rồi vote theo giờ', () {
      final s = _s(votes: {'An': true, 'Binh': true}, players: ['Cuong']);
      expect(s.seatHolders, ['Cuong', 'An', 'Binh']);
      expect(s.seatHolders, s.playersForClosing(),
          reason: 'danh sách bot báo phải trùng thứ tự sẽ giữ khi hết chỗ');
    });

    test('đang vote: người đã có trong danh sách nhắn "0" thì nhả chỗ', () {
      // Webhook chỉ ghi được vote, không sửa được danh sách chơi. Nếu danh
      // sách thắng vote "không" thì An vẫn bị giữ chỗ, bot vẫn đếm An, và lúc
      // chốt An vẫn bị trừ tiền dù đã báo không đi.
      final s = _s(votes: {'An': false}, players: ['An', 'Binh']);
      expect(s.seatHolders, ['Binh']);
      expect(s.seatsTaken, 1);
      expect(s.holdsSeat('An'), isFalse);
      expect(s.playersForClosing(), ['Binh'], reason: 'chốt cũng không được đưa An vào');
    });

    test('đang vote: được quản lý thêm mà chưa trả lời thì vẫn giữ chỗ', () {
      final s = _s(players: ['An']);
      expect(s.holdsSeat('An'), isTrue);
      expect(s.addedWithoutVote, ['An']);
    });

    test('đã chốt: có tên trong danh sách là giữ chỗ, vote cũ không còn tác dụng', () {
      final s = _s(
        votes: {'An': false, 'Binh': true}, players: ['An'],
        status: SessionStatus.closed,
      );
      expect(s.holdsSeat('An'), isTrue);
      expect(s.holdsSeat('Binh'), isFalse, reason: 'Bình bị cắt lúc chốt');
    });

    test('chốt → mở lại → C nhắn "0" → chốt lại: C ra khỏi danh sách, không bị trừ', () {
      // Lỗi người dùng gặp ở code cũ: mở lại vote giữ nguyên danh sách chơi,
      // C nhắn "0" chỉ đổi được vote (webhook không sửa được danh sách) nên C
      // vẫn trong danh sách và chốt lại vẫn bị trừ tiền.
      var s = _s(votes: {'An': true, 'Binh': true, 'Cuong': true}).asClosed();
      expect(s.playerIds, ['An', 'Binh', 'Cuong']);
      s = s.reopened(code: 1).copyWith(
            votes: {...s.votes, 'Cuong': false},
            voteTimes: {...s.voteTimes, 'Cuong': DateTime(2026, 11, 4, 10)},
          );
      expect(s.seatHolders, ['An', 'Binh'], reason: 'C báo không đi là ra ngay');
      expect(s.seatsTaken, 2);
      final closed = s.asClosed();
      expect(closed.playerIds, ['An', 'Binh']);
      final st = Settlement.computeSession(session: closed, commonFundAvailable: 0);
      expect(st.courtPerPlayer, {'An': 200000, 'Binh': 200000});
    });

    test('mở lại vote: người bị cắt lúc chốt (hết chỗ) không tự quay lại', () {
      // Không bỏ vote "đi" cũ của họ thì họ quay lại danh sách, chiếm chỗ, bot
      // báo hết chỗ oan với người khác - danh sách lúc mở lại phải đúng bằng
      // danh sách đã chốt.
      var s = _s(votes: {'An': true, 'Binh': true, 'Cuong': true}, comp: {'Binh': 1}, max: 2);
      s = s.asClosed();
      expect(s.playerIds, ['An', 'Binh'], reason: 'Cường bị cắt, đính kèm của Bình bị giảm');
      final o = s.reopened(code: 1);
      expect(o.seatHolders, ['An', 'Binh']);
      expect(o.seatsTaken, 2);
      expect(o.votes.containsKey('Cuong'), isFalse);
      expect(o.voteTimes.containsKey('Cuong'), isFalse);
    });

    test('mở lại vote: người trong danh sách được tính là đã vote đi', () {
      // Không làm vậy thì vote "không" cũ của An có hiệu lực lại và An mất chỗ.
      final s = _s(
        votes: {'An': false}, players: ['An', 'Binh'],
        status: SessionStatus.closed,
      ).reopened(code: 3);
      expect(s.status, SessionStatus.voting);
      expect(s.code, 3);
      expect(s.seatHolders, ['An', 'Binh']);
      expect(s.votes, {'An': true, 'Binh': true});
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
