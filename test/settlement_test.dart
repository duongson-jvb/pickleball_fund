import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/settlement.dart';
import 'package:pickleball_fund/utils/format.dart';

Session _session({
  int courtFee = 0,
  List<String> players = const [],
  int guests = 0,
  Map<String, int> drinkPrices = const {},
  Map<String, Map<String, int>> drinks = const {},
}) =>
    Session(
      id: 's1',
      title: 'Test',
      date: DateTime(2026, 10, 21),
      courtFee: courtFee,
      playerIds: players,
      guestCount: guests,
      drinkPrices: drinkPrices,
      drinks: drinks,
      createdAt: DateTime(2026, 10, 21),
    );

void main() {
  group('splitEqually', () {
    test('chia hết', () {
      expect(Settlement.splitEqually(300000, ['a', 'b', 'c']),
          {'a': 100000, 'b': 100000, 'c': 100000});
    });
    test('phần dư dồn về đầu danh sách, tổng không đổi', () {
      final r = Settlement.splitEqually(100000, ['a', 'b', 'c']);
      expect(r.values.fold(0, (x, y) => x + y), 100000);
      expect(r['a'], 33334);
      expect(r['c'], 33333);
    });
    test('danh sách rỗng', () {
      expect(Settlement.splitEqually(100, []), isEmpty);
    });
  });

  group('computeSession – tiền sân', () {
    test('quỹ chung đủ trả: không ai bị trừ', () {
      final st = Settlement.computeSession(
        session: _session(courtFee: 400000, players: ['a', 'b', 'c', 'd']),
        commonFundAvailable: 1000000,
      );
      expect(st.commonUsed, 400000);
      expect(st.courtPerPlayer, isEmpty);
      expect(st.perHead, 100000);
    });

    test('quỹ chung thiếu: phần thiếu chia đều', () {
      final st = Settlement.computeSession(
        session: _session(courtFee: 400000, players: ['a', 'b', 'c', 'd']),
        commonFundAvailable: 100000,
      );
      expect(st.commonUsed, 100000);
      expect(st.courtPerPlayer, {'a': 75000, 'b': 75000, 'c': 75000, 'd': 75000});
    });

    test('hết quỹ chung: chia toàn bộ', () {
      final st = Settlement.computeSession(
        session: _session(courtFee: 300000, players: ['a', 'b', 'c']),
        commonFundAvailable: 0,
      );
      expect(st.commonUsed, 0);
      expect(st.courtPerPlayer.values.fold(0, (x, y) => x + y), 300000);
    });

    test('có khách: khách trả tiền mặt, quỹ chung chỉ trả phần người chơi', () {
      final st = Settlement.computeSession(
        session: _session(courtFee: 500000, players: ['a', 'b', 'c', 'd'], guests: 1),
        commonFundAvailable: 0,
      );
      expect(st.participants, 5);
      expect(st.perHead, 100000);
      expect(st.guestCash, 100000);
      expect(st.courtPerPlayer, {'a': 100000, 'b': 100000, 'c': 100000, 'd': 100000});
    });

    test('sửa số người chơi thì tiền thay đổi', () {
      final s4 = Settlement.computeSession(
        session: _session(courtFee: 400000, players: ['a', 'b', 'c', 'd']),
        commonFundAvailable: 0,
      );
      final s5 = Settlement.computeSession(
        session: _session(courtFee: 400000, players: ['a', 'b', 'c', 'd', 'e']),
        commonFundAvailable: 0,
      );
      expect(s4.courtPerPlayer['a'], 100000);
      expect(s5.courtPerPlayer['a'], 80000);
    });
  });

  group('computeSession – tiền nước', () {
    test('mỗi người tự trả theo số lượng x giá buổi', () {
      final st = Settlement.computeSession(
        session: _session(
          courtFee: 0,
          players: ['a', 'b'],
          drinkPrices: {'revive': 15000, 'suoi': 10000},
          drinks: {
            'a': {'revive': 2, 'suoi': 1},
            'b': {'suoi': 3},
          },
        ),
        commonFundAvailable: 1000000,
      );
      expect(st.drinkPerPlayer, {'a': 40000, 'b': 30000});
      expect(st.totalDrinks, 70000);
      expect(st.commonUsed, 0);
    });
  });

  group('computeExpense', () {
    test('không chọn ai: chia tất cả, ưu tiên quỹ chung', () {
      final r = Settlement.computeExpense(
        expense: Expense(
            id: 'e', title: 'Mua bóng', amount: 250000,
            date: DateTime(2026), createdAt: DateTime(2026)),
        allActivePlayerIds: ['a', 'b', 'c', 'd', 'e'],
        commonFundAvailable: 50000,
      );
      expect(r.commonUsed, 50000);
      expect(r.perPlayer, {'a': 40000, 'b': 40000, 'c': 40000, 'd': 40000, 'e': 40000});
    });

    test('chọn người: chia cho người đó, không dùng quỹ chung', () {
      final r = Settlement.computeExpense(
        expense: Expense(
            id: 'e', title: 'Áo', amount: 300000, playerIds: ['a', 'b'],
            date: DateTime(2026), createdAt: DateTime(2026)),
        allActivePlayerIds: ['a', 'b', 'c'],
        commonFundAvailable: 1000000,
      );
      expect(r.commonUsed, 0);
      expect(r.perPlayer, {'a': 150000, 'b': 150000});
    });
  });

  group('DrinkType.priceOn', () {
    test('lấy giá của lần sửa gần nhất trước ngày chơi', () {
      final t = DrinkType(id: 'd', name: 'Revive', prices: [
        DrinkPrice(date: DateTime(2026, 1, 1), price: 10000),
        DrinkPrice(date: DateTime(2026, 6, 1), price: 12000),
        DrinkPrice(date: DateTime(2026, 12, 1), price: 15000),
      ]);
      expect(t.priceOn(DateTime(2026, 3, 1)), 10000);
      expect(t.priceOn(DateTime(2026, 6, 1)), 12000);
      expect(t.priceOn(DateTime(2026, 10, 21)), 12000);
      expect(t.priceOn(DateTime(2027, 1, 1)), 15000);
      expect(t.priceOn(DateTime(2025, 1, 1)), 10000);
    });
  });

  group('parseAmount', () {
    test('các định dạng nhập tiền', () {
      expect(parseAmount('50000'), 50000);
      expect(parseAmount('50.000'), 50000);
      expect(parseAmount('50k'), 50000);
      expect(parseAmount('1tr'), 1000000);
      expect(parseAmount('1,5tr'), 1500000);
      expect(parseAmount(''), 0);
    });
  });
}
