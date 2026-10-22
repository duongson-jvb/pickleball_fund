import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/services/zalo_commands.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

void main() {
  group('ZaloCommands.isHelp', () {
    test('nhận ra lệnh help ở nhiều dạng', () {
      for (final t in [
        'help',
        'Help',
        '@Bot PickleBall JVB help',
        '@Bot_PickleBall help?',
        'hướng dẫn',
        'huong dan dung bot',
        'trợ giúp',
        'menu',
        '?',
        '@Bot ?',
      ]) {
        expect(ZaloCommands.isHelp(t), isTrue, reason: t);
      }
    });
    test('không nhầm với vote hay chat thường', () {
      for (final t in ['1', '0', 'đi', 'không đi', 'mấy giờ?', 'helpme', 'không có']) {
        expect(ZaloCommands.isHelp(t), isFalse, reason: t);
      }
    });
    test('help không bị hiểu thành vote', () {
      expect(ZaloVoteSync.parseVote('@Bot help'), isNull);
    });
    test('nội dung help ngắn gọn, dưới 2000 ký tự và không quá 10 dòng', () {
      expect(ZaloCommands.helpText.length, lessThan(2000));
      expect(ZaloCommands.helpText.split('\n').length, lessThanOrEqualTo(10));
      expect(ZaloCommands.helpText, contains(ZaloCommands.appUrl));
    });
  });
}
