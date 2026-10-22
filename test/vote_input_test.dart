// Đọc tin vote: con số hợp lệ, con số gõ sai (phải báo lại), và câu chữ.
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

void main() {
  group('con số hợp lệ', () {
    test('0 = không đi', () {
      final r = ZaloVoteSync.readVote('0');
      expect(r.vote, isFalse);
      expect(r.isError, isFalse);
    });

    test('1..4 = đi, số suất tính cả người đính kèm', () {
      for (var n = 1; n <= ZaloVoteSync.maxVoteSeats; n++) {
        final r = ZaloVoteSync.readVote('$n');
        expect(r.vote, isTrue, reason: '$n');
        expect(r.seats, n, reason: '$n');
      }
    });

    test('chấp nhận "+1", "-1", "2 người", "3 suất", dấu chấm cuối câu', () {
      expect(ZaloVoteSync.readVote('+1').vote, isTrue);
      expect(ZaloVoteSync.readVote('-1').vote, isFalse);
      expect(ZaloVoteSync.readVote('2 người').seats, 2);
      expect(ZaloVoteSync.readVote('3 suất').seats, 3);
      expect(ZaloVoteSync.readVote('1.').vote, isTrue);
    });

    test('bỏ @mention bot trước khi đọc', () {
      final r = ZaloVoteSync.readVote('@Bot PickleBall JVB 2', botName: 'Bot PickleBall JVB');
      expect(r.vote, isTrue);
      expect(r.seats, 2);
    });
  });

  group('con số gõ sai → báo lại, không tính vote', () {
    for (final t in ['10', '01', '0.1', '1,0', '1,2,3', '99', '5', '9', '1 2', '0,0']) {
      test('"$t"', () {
        final r = ZaloVoteSync.readVote(t);
        expect(r.isError, isTrue, reason: 'phải báo lỗi');
        expect(r.vote, isNull, reason: 'không được tính thành vote');
        expect(r.seats, 0);
      });
    }

    test('câu báo lỗi nhắc lại tin đã gõ và số suất tối đa', () {
      final e = ZaloVoteSync.readVote('10').error!;
      expect(e, contains('10'));
      expect(e, contains('${ZaloVoteSync.maxVoteSeats}'));
    });

    test('số quá lớn không còn bị cắt thành số suất hợp lệ', () {
      // Trước đây "10" thành 10 suất (kèm 9 người) và bị trừ tiền sân 10 suất.
      expect(ZaloVoteSync.parseVoteCount('10'), isNull);
      expect(ZaloVoteSync.parseVoteCount('99'), isNull);
    });
  });

  group('câu chữ', () {
    test('câu ngắn có từ khoá vẫn tính như cũ', () {
      expect(ZaloVoteSync.readVote('đi').vote, isTrue);
      expect(ZaloVoteSync.readVote('cho em đi với').vote, isTrue);
      expect(ZaloVoteSync.readVote('hôm nay không đi được').vote, isFalse);
    });

    test('câu dài thì không tự tính, để quản lý quyết định', () {
      // "mai mình đi đá bóng nhé anh em ơi" không được tính thành đi chơi pickleball.
      final r = ZaloVoteSync.readVote('mai mình đi đá bóng nhé anh em ơi');
      expect(r.vote, isNull);
      expect(r.isError, isFalse, reason: 'không phải lỗi, chỉ là không chắc');
    });

    test('tin rỗng', () {
      expect(ZaloVoteSync.readVote('').vote, isNull);
      expect(ZaloVoteSync.readVote('').isError, isFalse);
    });
  });
}
