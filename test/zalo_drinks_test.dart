import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/zalo_drinks.dart';

DrinkType _t(String id, String name) => DrinkType(
    id: id, name: name, prices: [DrinkPrice(date: DateTime(2026), price: 10000)]);

void main() {
  final revive = _t('rv', 'Revive');
  final suoi = _t('su', 'Nước suối');
  final trada = _t('td', 'Trà đá');

  group('ZaloDrinks.looksLikeDrink', () {
    test('nhận ra tin ghi nước (có số), không nhầm vote hay câu nói', () {
      expect(ZaloDrinks.looksLikeDrink('nước 2', [revive]), isTrue);
      expect(ZaloDrinks.looksLikeDrink('@Bot nước revive 2', [revive], botName: 'Bot'), isTrue);
      expect(ZaloDrinks.looksLikeDrink('revive 2', [revive]), isTrue);
      expect(ZaloDrinks.looksLikeDrink('+1 revive', [revive]), isTrue);
      expect(ZaloDrinks.looksLikeDrink('1', [revive]), isFalse);
      expect(ZaloDrinks.looksLikeDrink('đi', [revive]), isFalse);
      expect(ZaloDrinks.looksLikeDrink('revive ngon', [revive]), isFalse, reason: 'tên không kèm số');
      expect(ZaloDrinks.looksLikeDrink('uống nước không', [revive]), isFalse, reason: 'không có số');
    });
  });

  group('ZaloDrinks.parse', () {
    test('một loại nước: "nước 2" đặt = 2, "+1 nước" cộng 1', () {
      final c = ZaloDrinks.parse('nước 2', [revive]);
      expect(c.isValid, isTrue);
      expect(c.changes.single.drinkTypeId, 'rv');
      expect(c.changes.single.qty, 2);
      expect(c.changes.single.relative, isFalse);
      final c2 = ZaloDrinks.parse('+1 nước', [revive]);
      expect(c2.changes.single.relative, isTrue);
      expect(c2.changes.single.qty, 1);
    });
    test('nhiều loại: cần ghi tên, hiểu cả số trước và sau tên, có dấu phẩy', () {
      final c = ZaloDrinks.parse('nước revive 2, 1 nước suối', [revive, suoi]);
      expect(c.isValid, isTrue);
      expect({for (final x in c.changes) x.drinkTypeId: x.qty}, {'rv': 2, 'su': 1});
      final c2 = ZaloDrinks.parse('nước 2', [revive, suoi]);
      expect(c2.isValid, isFalse);
      expect(c2.error, contains('2 loại'));
    });
    test('tên dài ưu tiên, không dấu, cộng/trừ', () {
      final c = ZaloDrinks.parse('tra da +2, revive -1', [revive, suoi, trada]);
      expect({for (final x in c.changes) x.drinkTypeId: x.qty}, {'td': 2, 'rv': -1});
      expect(c.changes.every((x) => x.relative), isTrue);
    });
    test('không có số → lỗi; thiếu số cho một loại → báo rõ, không bỏ qua', () {
      expect(ZaloDrinks.parse('nước', [revive]).isValid, isFalse);
      final rv1 = DrinkType(id: 'rv', name: 'Revive', code: 1);
      final su2 = DrinkType(id: 'su', name: 'Nước suối', code: 2);
      final c = ZaloDrinks.parse('n1 2 n2', [rv1, su2]);
      expect(c.isValid, isFalse);
      expect(c.error, contains('Nước suối'));
    });
  });

  group('Mã ngắn N1/N2 và danh sách nước', () {
    final rv1 = DrinkType(id: 'rv', name: 'Revive', code: 1,
        prices: [DrinkPrice(date: DateTime(2026), price: 15000)]);
    final su2 = DrinkType(id: 'su', name: 'Nước suối', code: 2,
        prices: [DrinkPrice(date: DateTime(2026), price: 10000)]);

    test('gõ theo mã: "N1 2, n2 1", "+1 #1"', () {
      final c = ZaloDrinks.parse('N1 2, n2 1', [rv1, su2]);
      expect({for (final x in c.changes) x.drinkTypeId: x.qty}, {'rv': 2, 'su': 1});
      final c2 = ZaloDrinks.parse('+1 #1', [rv1, su2]);
      expect(c2.changes.single.drinkTypeId, 'rv');
      expect(c2.changes.single.relative, isTrue);
      expect(ZaloDrinks.looksLikeDrink('N1 2', [rv1, su2]), isTrue);
    });

    test('"@bot nước" là yêu cầu xem danh sách, "nước 2" thì không', () {
      expect(ZaloDrinks.isListRequest('@Bot PickleBall JVB nước', botName: 'Bot PickleBall JVB'), isTrue);
      expect(ZaloDrinks.isListRequest('nước?'), isTrue);
      expect(ZaloDrinks.isListRequest('giá nước'), isTrue);
      expect(ZaloDrinks.isListRequest('menu nuoc'), isTrue);
      expect(ZaloDrinks.isListRequest('nước 2'), isFalse);
      expect(ZaloDrinks.isListRequest('1'), isFalse);
    });

    test('danh sách có mã, tên, giá theo ngày, sắp theo mã', () {
      final text = ZaloDrinks.listText([su2, rv1], on: DateTime(2026, 6, 1));
      expect(text, contains('N1 · Revive · 15.000đ'));
      expect(text, contains('N2 · Nước suối · 10.000đ'));
      expect(text.indexOf('N1'), lessThan(text.indexOf('N2')));
      expect(text, contains('"N1 2"'));
    });
  });

  group('Nhập hộ bằng @tên (parseMulti)', () {
    final rv1 = DrinkType(id: 'rv', name: 'Revive', code: 1);
    final su2 = DrinkType(id: 'su', name: 'Nước suối', code: 2);
    Player p(String id, String name) => Player(id: id, name: name, createdAt: DateTime(2026));
    final players = [p('an', 'An'), p('binh', 'Nguyễn Văn Bình'), p('chi', 'Chi'), p('chien', 'Chiến')];

    test('tự mình + hai người khác trong một tin, tên có dấu cách, không phân biệt hoa thường', () {
      final r = ZaloDrinks.parseMulti(
          '@Bot PickleBall JVB n1 2 @an N2 1 @nguyen van binh REVIVE 2, suối 1',
          [rv1, su2], players, botName: 'Bot PickleBall JVB');
      expect(r.length, 3);
      expect(r[0].isSelf, isTrue);
      expect(r[0].command.changes.single.drinkTypeId, 'rv');
      expect(r[1].player?.id, 'an');
      expect(r[1].command.changes.single.drinkTypeId, 'su');
      expect(r[2].player?.id, 'binh');
      expect({for (final c in r[2].command.changes) c.drinkTypeId: c.qty}, {'rv': 2, 'su': 1});
    });

    test('tên viết tắt duy nhất thì khớp; mơ hồ thì báo không tìm thấy', () {
      final r = ZaloDrinks.parseMulti('@Bình N1 1 @Chi N1 1 @Hùng N1 1', [rv1, su2], players);
      expect(r[0].player?.id, 'binh');
      expect(r[1].player?.id, 'chi');
      expect(r[2].player, isNull);
      expect(r[2].nameText, 'hung');
    });

    test('thiếu số lượng cho người được @ → lệnh không hợp lệ', () {
      final r = ZaloDrinks.parseMulti('@An revive', [rv1, su2], players);
      expect(r.single.player?.id, 'an');
      expect(r.single.command.isValid, isFalse);
    });

    test('@bot không có tên bot trong cài đặt → lệnh cho chính mình', () {
      final r = ZaloDrinks.parseMulti('@bot nuoc revive 2', [rv1, su2], players);
      expect(r.single.isSelf, isTrue);
      expect(r.single.command.changes.single.qty, 2);
    });
  });

  group('ZaloDrinks.applyChanges / pickSession', () {
    test('áp dụng đặt và cộng, về 0 thì xoá', () {
      var d = ZaloDrinks.applyChanges({}, 'p', [const DrinkChange('rv', 2)]);
      expect(d, {'p': {'rv': 2}});
      d = ZaloDrinks.applyChanges(d, 'p', [const DrinkChange('rv', 1, relative: true)]);
      expect(d['p']!['rv'], 3);
      d = ZaloDrinks.applyChanges(d, 'p', [const DrinkChange('rv', -3, relative: true)]);
      expect(d, isEmpty);
    });
    test('chọn buổi gần nhất mà người đó (hoặc host của đính kèm) tham gia', () {
      final now = DateTime(2026, 10, 25, 20);
      final sessions = [
        Session(id: 'old', title: '', date: DateTime(2026, 10, 18, 18), playerIds: const ['p'], createdAt: now),
        Session(id: 'today', title: '', date: DateTime(2026, 10, 25, 18), playerIds: const ['p'], createdAt: now),
        Session(id: 'other', title: '', date: DateTime(2026, 10, 25, 18), playerIds: const ['q'], createdAt: now),
        Session(id: 'next', title: '', date: DateTime(2026, 10, 27, 18), playerIds: const ['p'], createdAt: now),
      ];
      expect(ZaloDrinks.pickSession(sessions, 'p', now)?.id, 'today');
      expect(ZaloDrinks.pickSession(sessions, 'p#1', now)?.id, 'today');
      expect(ZaloDrinks.pickSession(sessions, 'q', now)?.id, 'other');
      expect(ZaloDrinks.pickSession(sessions, 'x', now), isNull);
    });
  });
}
