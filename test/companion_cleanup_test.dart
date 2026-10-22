// Dọn dấu vết của người đính kèm: nước của người đính kèm đã bị bỏ không được
// tính nữa, và xoá người chơi phải gỡ cả nước của người đính kèm đi cùng họ.
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/settlement.dart';

Session _session({
  List<String> players = const ['p1', 'p2'],
  Map<String, int> companions = const {},
  Map<String, Map<String, int>> drinks = const {},
  int courtFee = 0,
}) =>
    Session(
      id: 's1',
      title: 'Test',
      date: DateTime(2026, 10, 20, 18),
      courtFee: courtFee,
      playerIds: players,
      companions: companions,
      drinkPrices: const {'d1': 15000},
      drinks: drinks,
      createdAt: DateTime(2026, 10, 19),
    );

void main() {
  group('pruneCompanionDrinks', () {
    test('bỏ người đính kèm thì nước của họ không còn được tính', () {
      final s = _session(
        companions: const {}, // đã bỏ đính kèm
        drinks: const {'p1#1': {'d1': 2}},
      );
      final pruned = s.pruneCompanionDrinks();
      expect(pruned.drinks, isEmpty);
      final r = Settlement.computeSession(session: pruned, commonFundAvailable: 0);
      expect(r.drinkPerPlayer['p1'] ?? 0, 0);
    });

    test('giảm từ 2 xuống 1 thì chỉ bỏ người đính kèm thứ hai', () {
      final s = _session(
        companions: const {'p1': 1},
        drinks: const {
          'p1': {'d1': 1},
          'p1#1': {'d1': 1},
          'p1#2': {'d1': 5},
        },
      );
      final pruned = s.pruneCompanionDrinks();
      expect(pruned.drinks.keys.toSet(), {'p1', 'p1#1'});
      final r = Settlement.computeSession(session: pruned, commonFundAvailable: 0);
      expect(r.drinkPerPlayer['p1'], 30000, reason: '2 chai, không phải 7 chai');
    });

    test('còn đủ người đính kèm thì giữ nguyên, không tạo bản sao thừa', () {
      final s = _session(
        companions: const {'p1': 1},
        drinks: const {'p1#1': {'d1': 2}},
      );
      expect(identical(s.pruneCompanionDrinks(), s), isTrue);
    });
  });

  group('withoutPlayer / mentions', () {
    final s = _session(
      players: const ['p1', 'p2'],
      companions: const {'p1': 1},
      drinks: const {
        'p1': {'d1': 1},
        'p1#1': {'d1': 2},
        'p2': {'d1': 1},
      },
    ).copyWith(
      votes: const {'p1': true, 'p2': true},
      voteTimes: {'p1': DateTime(2026, 10, 19), 'p2': DateTime(2026, 10, 19)},
    );

    test('gỡ sạch mọi dấu vết, kể cả nước của người đính kèm', () {
      final out = s.withoutPlayer('p1');
      expect(out.playerIds, ['p2']);
      expect(out.votes.containsKey('p1'), isFalse);
      expect(out.voteTimes.containsKey('p1'), isFalse);
      expect(out.companions.containsKey('p1'), isFalse);
      expect(out.drinks.keys.toSet(), {'p2'},
          reason: 'nước của p1 và của người đính kèm p1#1 phải bị gỡ');
      expect(out.mentions('p1'), isFalse);
    });

    test('không đụng tới người khác', () {
      final out = s.withoutPlayer('p1');
      expect(out.mentions('p2'), isTrue);
      expect(out.drinks['p2'], {'d1': 1});
    });

    test('mentions bắt được cả dấu vết chỉ còn ở nước của người đính kèm', () {
      final only = _session(players: const ['p2'], drinks: const {'p1#1': {'d1': 1}});
      expect(only.mentions('p1'), isTrue);
    });
  });
}
