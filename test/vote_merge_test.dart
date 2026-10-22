// Giữ vote mà webhook vừa ghi khi màn hình lưu buổi từ một bản chụp cũ.
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';

Session _s({
  Map<String, bool> votes = const {},
  Map<String, DateTime> voteTimes = const {},
  Map<String, int> companions = const {},
}) =>
    Session(
      id: 's1', title: 'B', date: DateTime(2026, 10, 25, 18),
      votes: votes, voteTimes: voteTimes, companions: companions,
      createdAt: DateTime(2026, 10, 20),
    );

final t1 = DateTime(2026, 10, 21, 10);
final t2 = DateTime(2026, 10, 21, 11);

void main() {
  group('mergeNewerVotes', () {
    test('vote mới tới sau lúc chụp thì được giữ lại', () {
      final banCu = _s(votes: {'a': true}, voteTimes: {'a': t1});
      final mayChu = _s(votes: {'a': true, 'b': true}, voteTimes: {'a': t1, 'b': t2});
      final out = banCu.mergeNewerVotes(mayChu);
      expect(out.votes['b'], isTrue, reason: 'vote của b bị mất');
      expect(out.voteTimes['b'], t2);
      expect(out.votes['a'], isTrue);
    });

    test('người đính kèm đi kèm vote mới cũng được giữ', () {
      final banCu = _s();
      final mayChu = _s(votes: {'b': true}, voteTimes: {'b': t2}, companions: {'b': 2});
      final out = banCu.mergeNewerVotes(mayChu);
      expect(out.companions['b'], 2);
    });

    test('quản lý tự bật/tắt trên giao diện KHÔNG bị máy chủ đè', () {
      // Giao diện đổi votes mà không đụng voteTimes → mốc thời gian bằng nhau.
      final banSua = _s(votes: {'a': false}, voteTimes: {'a': t1});
      final mayChu = _s(votes: {'a': true}, voteTimes: {'a': t1});
      final out = banSua.mergeNewerVotes(mayChu);
      expect(out.votes['a'], isFalse, reason: 'thao tác của quản lý bị ghi đè');
    });

    test('máy chủ có mốc mới hơn thì máy chủ thắng (người đó vừa đổi ý)', () {
      final banCu = _s(votes: {'a': true}, voteTimes: {'a': t1});
      final mayChu = _s(votes: {'a': false}, voteTimes: {'a': t2});
      final out = banCu.mergeNewerVotes(mayChu);
      expect(out.votes['a'], isFalse);
      expect(out.companions.containsKey('a'), isFalse);
    });

    test('không có gì mới thì trả về đúng đối tượng cũ', () {
      final banCu = _s(votes: {'a': true}, voteTimes: {'a': t1});
      expect(identical(banCu.mergeNewerVotes(banCu), banCu), isTrue);
    });

    test('bỏ đính kèm ở máy chủ thì cũng bỏ theo', () {
      final banCu = _s(votes: {'a': true}, voteTimes: {'a': t1}, companions: {'a': 2});
      final mayChu = _s(votes: {'a': true}, voteTimes: {'a': t2});
      final out = banCu.mergeNewerVotes(mayChu);
      expect(out.companions.containsKey('a'), isFalse);
    });
  });
}
