import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

void main() {
  Player p(String id, String name) => Player(id: id, name: name, createdAt: DateTime(2026));
  final players = [
    p('an', 'An'),
    p('binh', 'Nguyễn Văn Bình'),
    p('chi', 'Chi'),
    p('chien', 'Chiến'),
    Player(id: 'tung', name: 'Tùng', zaloName: 'Tung Dep Trai', createdAt: DateTime(2026)),
  ];
  const bot = 'Bot PickleBall JVB';

  group('ZaloVoteSync.parseProxyVotes', () {
    test('"@An 1" → An đi; có @bot ở đầu vẫn đọc được', () {
      final r = ZaloVoteSync.parseProxyVotes('@$bot @An 1', players, botName: bot)!;
      expect(r.length, 1);
      expect(r.single.player?.id, 'an');
      expect(r.single.isSelf, isFalse);
      expect(r.single.reading.vote, isTrue);
      expect(r.single.reading.seats, 1);
    });
    test('nhiều người, tên có dấu cách, không phân biệt hoa thường, "0" và "2"', () {
      final r = ZaloVoteSync.parseProxyVotes('@nguyen van binh 0 @AN 2', players)!;
      expect(r.length, 2);
      expect(r[0].player?.id, 'binh');
      expect(r[0].reading.vote, isFalse);
      expect(r[1].player?.id, 'an');
      expect(r[1].reading.seats, 2);
    });
    test('phần trước @ đầu tiên là vote của chính người gửi', () {
      final r = ZaloVoteSync.parseProxyVotes('1 @An không đi', players)!;
      expect(r.length, 2);
      expect(r[0].isSelf, isTrue);
      expect(r[0].reading.vote, isTrue);
      expect(r[1].player?.id, 'an');
      expect(r[1].reading.vote, isFalse);
    });
    test('tên chưa có trong danh sách → giữ tên để báo, không đoán bừa', () {
      final r = ZaloVoteSync.parseProxyVotes('@Người Lạ 1', players)!;
      expect(r.single.player, isNull);
      expect(r.single.nameText, 'nguoi la');
      expect(r.single.reading.vote, isTrue);
    });
    test('tên hiển thị Zalo đã nhớ và tên dài chứa tên app đều khớp', () {
      expect(ZaloVoteSync.parseProxyVotes('@Tung Dep Trai 1', players)!.single.player?.id, 'tung');
      expect(ZaloVoteSync.parseProxyVotes('@Nguyễn Văn An 0', players)!.single.player?.id, 'an');
      // Một từ trọn vẹn của tên, duy nhất → khớp (giống nhập hộ nước và khớp người gửi).
      expect(ZaloVoteSync.parseProxyVotes('@Văn 1', players)!.single.player?.id, 'binh');
      // Không có ai → không khớp bừa.
      expect(ZaloVoteSync.parseProxyVotes('@Hùng 1', players)!.single.player, isNull);
    });
    test('tên viết tắt mơ hồ ("Chi" vs "Chiến") khớp đúng người tên Chi', () {
      final r = ZaloVoteSync.parseProxyVotes('@Chi 1', players)!;
      expect(r.single.player?.id, 'chi');
    });
    test('số sai "@An 10" → báo lỗi, không tính', () {
      final r = ZaloVoteSync.parseProxyVotes('@An 10', players)!;
      expect(r.single.reading.isError, isTrue);
    });
    test('câu hỏi / câu nói có @tên KHÔNG phải vote hộ', () {
      expect(ZaloVoteSync.parseProxyVotes('@An đi không?', players), isNull);
      expect(ZaloVoteSync.parseProxyVotes('@An mai đi sớm nhé anh ơi', players), isNull);
      expect(ZaloVoteSync.parseProxyVotes('anh Sơn bảo @An oke rồi', players), isNull);
      expect(ZaloVoteSync.parseProxyVotes('1', players), isNull);
      expect(ZaloVoteSync.parseProxyVotes('mail toi@abc.com', players), isNull);
    });
    test('mentionsOther: có @người khác ngoài bot', () {
      expect(ZaloVoteSync.mentionsOther('@$bot @An đi không?', botName: bot), isTrue);
      expect(ZaloVoteSync.mentionsOther('@$bot 1', botName: bot), isFalse);
      expect(ZaloVoteSync.mentionsOther('1'), isFalse);
    });
    test('"@bot 1" khi chưa lưu tên bot → vote của chính người gửi', () {
      final r = ZaloVoteSync.parseProxyVotes('@bot 1', players)!;
      expect(r.single.isSelf, isTrue);
      expect(r.single.reading.vote, isTrue);
    });
    test('một người hợp lệ + một người gõ sai → vẫn trả cả hai để báo từng dòng', () {
      final r = ZaloVoteSync.parseProxyVotes('@An 1 @Chi đi ăn cơm nhé', players)!;
      expect(r.length, 2);
      expect(r[0].reading.vote, isTrue);
      expect(r[1].reading.isError, isTrue);
    });
  });
}
