// Lệnh ghi nước và tin vote dùng chung một số ký tự ("+1 N1" có "+1",
// "N1 0" có "0"), nên THỨ TỰ kiểm là quan trọng: phải xét lệnh nước trước.
// Webhook cũng phải theo đúng thứ tự này (hasDrinkMarker trước readVoteShape),
// nếu không lệnh nước sẽ bị nuốt thành vote.
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/zalo_drinks.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

DrinkType _d(String id, String name, int price, {int code = 0}) => DrinkType(
    id: id, name: name, code: code,
    prices: [DrinkPrice(date: DateTime(2026, 1, 1), price: price)]);

void main() {
  final types = [_d('d1', 'Revive', 15000, code: 1), _d('d2', 'Nước suối', 5000, code: 2)];

  group('tin vừa giống lệnh nước vừa giống vote → phải là lệnh nước', () {
    for (final t in ['+1 n1', '+1 revive', 'n1 0', 'n2 0', '+1 nước', 'n1 2, n2 1']) {
      test('"$t"', () {
        expect(ZaloDrinks.looksLikeDrink(t, types), isTrue,
            reason: 'phải nhận ra là lệnh ghi nước');
        // readVote cũng "hiểu" được tin này → chứng minh vì sao phải xét nước trước.
        final r = ZaloVoteSync.readVote(t);
        expect(r.vote != null || r.isError, isTrue,
            reason: 'nếu readVote ngừng nhận tin này thì test mất ý nghĩa, '
                'nhưng thứ tự kiểm vẫn phải giữ');
      });
    }
  });

  group('tin vote thuần không được nhầm thành lệnh nước', () {
    for (final t in ['0', '1', '2', '3', '4', 'đi', 'không đi']) {
      test('"$t"', () {
        expect(ZaloDrinks.looksLikeDrink(t, types), isFalse);
      });
    }
  });

  group('lệnh nước thuần không được nhầm thành vote chắc chắn', () {
    for (final t in ['n1 2', 'revive 2', 'nước 2']) {
      test('"$t"', () {
        expect(ZaloDrinks.looksLikeDrink(t, types), isTrue);
        expect(ZaloVoteSync.readVote(t).vote, isNull);
      });
    }
  });
}
