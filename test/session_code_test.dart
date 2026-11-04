// Nhiều buổi cùng mở vote: mã buổi ("B1", "B2") phải đưa vote về đúng buổi,
// và phần còn lại của tin vẫn đọc như vote thường.
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/zalo_bot_service.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

Session _s({
  required String id,
  required int code,
  required DateTime date,
  SessionStatus status = SessionStatus.voting,
}) =>
    Session(
      id: id,
      title: 'Buổi $code',
      date: date,
      courtFee: 300000,
      code: code,
      status: status,
      createdAt: DateTime(2026, 10, 29),
    );

ZaloUpdate _u(String text) => ZaloUpdate(
      eventName: 'message.text.received',
      messageId: 'm',
      chatId: 'g',
      fromId: 'z1',
      fromName: 'An',
      chatType: 'GROUP',
      text: text,
      date: DateTime(2026, 11, 1, 9),
    );

void main() {
  group('đọc mã buổi', () {
    test('"B2 1" → buổi 2', () {
      expect(ZaloVoteSync.sessionCodeIn('B2 1'), 2);
      expect(ZaloVoteSync.sessionCodeIn('b2 1'), 2);
      expect(ZaloVoteSync.sessionCodeIn('@bot B1 0'), 1);
      expect(ZaloVoteSync.sessionCodeIn('1 B3'), 3);
    });

    test('tên kiểu "Tuấn B" không bị đọc thành mã buổi', () {
      // "b" phải dính liền số; tách rời là một phần của tên người.
      expect(ZaloVoteSync.sessionCodeIn('@Tuấn B 1'), 0);
      expect(ZaloVoteSync.sessionCodeIn('b 2 đi'), 0);
      final players = [
        Player(id: 'tb', name: 'Tuấn B', createdAt: DateTime(2026, 1, 1)),
      ];
      final parts = ZaloVoteSync.parseProxyVotes('@Tuấn B 1', players);
      expect(parts, isNotNull, reason: 'vote hộ cho Tuấn B không được mất');
      expect(parts!.single.player?.id, 'tb');
      expect(parts.single.reading.vote, isTrue);
      expect(parts.single.reading.seats, 1);
    });

    test('tin không có mã → 0', () {
      for (final t in ['1', '0', 'đi', 'không đi', '2 người', 'bạn 2', 'N1 2']) {
        expect(ZaloVoteSync.sessionCodeIn(t), 0, reason: t);
      }
    });
  });

  group('mã buổi không làm sai nội dung vote', () {
    test('"B2 1" vẫn là đi 1 suất', () {
      final r = ZaloVoteSync.readVote('B2 1');
      expect(r.vote, isTrue);
      expect(r.seats, 1);
      expect(r.isError, isFalse);
    });

    test('"B1 2" là đi 2 suất, không phải buổi B12', () {
      expect(ZaloVoteSync.sessionCodeIn('B1 2'), 1);
      expect(ZaloVoteSync.readVote('B1 2').seats, 2);
    });

    test('"B2 0" là không đi', () {
      expect(ZaloVoteSync.readVote('B2 0').vote, isFalse);
    });

    test('mã hai chữ số không bị đọc thành số suất sai', () {
      // Chưa bỏ mã thì "B10 1" đọc ra số 10 và báo "nhập sai".
      final r = ZaloVoteSync.readVote('B10 1');
      expect(r.isError, isFalse);
      expect(r.vote, isTrue);
      expect(r.seats, 1);
    });

    test('hai mã đứng liền nhau đều được bỏ, mã đầu là mã buổi', () {
      expect(ZaloVoteSync.sessionCodeIn('B12 B1 1'), 12);
      final r = ZaloVoteSync.readVote('B12 B1 1');
      expect(r.vote, isTrue);
      expect(r.seats, 1);
      // Bỏ hết mã thì "0.1" còn lại phải bị báo gõ sai (webhook từng đọc thành "không").
      expect(ZaloVoteSync.readVote('b12 0.1 B10').isError, isTrue);
    });

    test('số gõ sai vẫn bị báo khi có mã buổi', () {
      expect(ZaloVoteSync.readVote('B2 10').isError, isTrue);
    });

    test('vote hộ kèm mã buổi: "B2 @An 1"', () {
      final players = [
        Player(id: 'a', name: 'An', createdAt: DateTime(2026, 1, 1)),
      ];
      final parts = ZaloVoteSync.parseProxyVotes('B2 @An 1', players);
      expect(parts, isNotNull);
      expect(parts!.length, 1);
      expect(parts.first.player?.id, 'a');
      expect(parts.first.reading.vote, isTrue);
    });
  });

  group('chia tin về đúng buổi', () {
    final b1 = _s(id: 's1', code: 1, date: DateTime(2026, 11, 2, 18));
    final b2 = _s(id: 's2', code: 2, date: DateTime(2026, 11, 5, 18));
    final open = [b1, b2];

    test('có mã → buổi mang mã đó', () {
      expect(ZaloVoteSync.sessionFor(_u('B2 1'), open, b1)?.id, 's2');
      expect(ZaloVoteSync.sessionFor(_u('B1 0'), open, b1)?.id, 's1');
    });

    test('không có mã → buổi gần nhất', () {
      expect(ZaloVoteSync.sessionFor(_u('1'), open, b1)?.id, 's1');
    });

    test('mã không đang mở (buổi đã chốt / gõ sai) → không tính sang buổi khác', () {
      // Trước đây rơi về buổi gần nhất: "B1 1" khi B1 vừa chốt thành vote buổi CN.
      expect(ZaloVoteSync.sessionFor(_u('B9 1'), open, b1), isNull);
      expect(ZaloVoteSync.unknownCodeText(9, open), contains('không có buổi B9'));
      expect(ZaloVoteSync.unknownCodeText(9, open), contains('B2'));
    });

    test('votingSessions: chỉ buổi đang vote, buổi gần nhất trước', () {
      final closed = _s(
          id: 's0', code: 3, date: DateTime(2026, 10, 20, 18),
          status: SessionStatus.closed);
      final list = ZaloVoteSync.votingSessions([b2, closed, b1]);
      expect(list.map((e) => e.id).toList(), ['s1', 's2']);
    });
  });

  group('cấp mã buổi', () {
    final d = DateTime(2026, 11, 2);
    Session closed(String id, int code) =>
        _s(id: id, code: code, date: d, status: SessionStatus.closed);

    test('nhãn mã', () {
      expect(_s(id: 'x', code: 0, date: d).codeLabel, '');
      expect(_s(id: 'x', code: 2, date: d).codeLabel, 'B2');
    });

    test('buổi mới lấy số nhỏ nhất chưa dùng trong các buổi còn mở', () {
      expect(Session.nextCode([]), 1);
      expect(Session.nextCode([_s(id: 'a', code: 1, date: d), _s(id: 'b', code: 3, date: d)]), 2);
      // Buổi đã chốt nhường mã lại.
      expect(Session.nextCode([closed('a', 1), _s(id: 'b', code: 2, date: d)]), 1);
    });

    test('mở lại vote: giữ mã cũ nếu còn trống, trùng thì lấy mã mới', () {
      final old = closed('old', 1);
      expect(Session.codeForReopen([old], old), 1);
      // Mã 1 đã nhường cho buổi mới → mở lại phải lấy mã khác, không được trùng.
      expect(Session.codeForReopen([old, _s(id: 'new', code: 1, date: d)], old), 2);
      // Buổi cũ chưa từng có mã.
      expect(Session.codeForReopen([closed('old', 0)], closed('old', 0)), 1);
    });

    test('gán lại: buổi chưa có mã, và buổi tạo trước khi trùng mã', () {
      Session open(String id, int code, int createdDay, {int day = 5}) => Session(
            id: id, title: id, date: DateTime(2026, 11, day), code: code,
            createdAt: DateTime(2026, 10, createdDay),
          );
      expect(Session.codeFixes([open('a', 1, 1), open('b', 2, 2)]), isEmpty);
      // Trùng mã 1: "sau" (tạo sau) giữ, "truoc" đổi sang số trống nhỏ nhất.
      expect(Session.codeFixes([open('truoc', 1, 1), open('sau', 1, 9), open('c', 2, 5)]),
          {'truoc': 3});
      // Chưa có mã: buổi diễn ra trước lấy số nhỏ trước.
      expect(Session.codeFixes([open('x', 0, 1, day: 9), open('y', 0, 1, day: 3)]),
          {'y': 1, 'x': 2});
      // Buổi đã chốt không bị đụng tới.
      expect(Session.codeFixes([closed('z', 0)]), isEmpty);
    });
  });
}
