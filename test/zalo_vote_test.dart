import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/zalo_bot_service.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

Player _p(String id, String name, {String zaloId = ''}) =>
    Player(id: id, name: name, zaloId: zaloId, createdAt: DateTime(2026));

void main() {
  group('parseVote', () {
    test('đi', () {
      for (final t in ['1', '+1', 'đi', 'Đi nhé', 'ok', 'có', 'tham gia', 'join', 'dk', 'yes']) {
        expect(ZaloVoteSync.parseVote(t), isTrue, reason: t);
      }
    });
    test('không đi', () {
      for (final t in ['0', '-1', 'không', 'ko đi', 'k', 'nghỉ', 'bận rồi', 'hôm nay không đi được']) {
        expect(ZaloVoteSync.parseVote(t), isFalse, reason: t);
      }
    });
    test('không rõ', () {
      expect(ZaloVoteSync.parseVote('mấy giờ vậy?'), isNull);
      expect(ZaloVoteSync.parseVote(''), isNull);
    });
    test('bỏ phần @mention bot', () {
      expect(ZaloVoteSync.parseVote('@Bot PickleBall JVB 1', botName: 'Bot PickleBall JVB'), isTrue);
      expect(ZaloVoteSync.parseVote('@Bot PickleBall JVB không', botName: 'Bot PickleBall JVB'), isFalse);
    });
  });

  group('matchPlayer', () {
    final players = [
      _p('a', 'Nguyễn Văn An', zaloId: 'z-an'),
      _p('b', 'Bình'),
      _p('c', 'Bình Minh'),
      _p('d', 'Sơn'),
    ];
    test('ưu tiên zaloId', () {
      expect(ZaloVoteSync.matchPlayer(zaloId: 'z-an', zaloName: 'Tên khác', players: players)?.id, 'a');
    });
    test('khớp tên chính xác, không dấu', () {
      expect(ZaloVoteSync.matchPlayer(zaloId: 'x', zaloName: 'son', players: players)?.id, 'd');
    });
    test('khớp một phần chỉ khi duy nhất', () {
      // "Bình" khớp cả Bình lẫn Bình Minh theo partial, nhưng exact là Bình.
      expect(ZaloVoteSync.matchPlayer(zaloId: 'x', zaloName: 'Bình', players: players)?.id, 'b');
      // "Minh" chỉ nằm trong "Bình Minh".
      expect(ZaloVoteSync.matchPlayer(zaloId: 'x', zaloName: 'Minh', players: players)?.id, 'c');
      // Không khớp ai.
      expect(ZaloVoteSync.matchPlayer(zaloId: 'x', zaloName: 'Hùng', players: players), isNull);
    });
  });

  group('ZaloUpdate.tryParse', () {
    test('đọc payload theo định dạng webhook/getUpdates', () {
      final u = ZaloUpdate.tryParse({
        'event_name': 'message.text.received',
        'message': {
          'from': {'id': 'u1', 'display_name': 'Ted', 'is_bot': false},
          'chat': {'id': 'g1', 'chat_type': 'GROUP'},
          'text': '1',
          'message_id': 'm1',
          'date': 1750316131602,
        },
      });
      expect(u, isNotNull);
      expect(u!.fromId, 'u1');
      expect(u.fromName, 'Ted');
      expect(u.chatId, 'g1');
      expect(u.isGroup, isTrue);
      expect(u.text, '1');
      expect(u.date.year, 2025);
    });
  });

  group('pickTarget', () {
    test('chọn buổi đang vote sắp tới gần nhất', () {
      final now = DateTime.now();
      final sessions = [
        Session(id: 'old', title: '', date: now.subtract(const Duration(days: 7)), createdAt: now),
        Session(id: 'soon', title: '', date: now.add(const Duration(days: 1)), createdAt: now),
        Session(id: 'later', title: '', date: now.add(const Duration(days: 3)), createdAt: now),
        Session(id: 'closed', title: '', date: now, status: SessionStatus.closed, createdAt: now),
      ];
      expect(ZaloVoteSync.pickTarget(sessions)?.id, 'soon');
    });
  });
}
