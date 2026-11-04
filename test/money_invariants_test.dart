// Kiểm bất biến của phần tính tiền và đếm suất trên hàng nghìn buổi chơi sinh
// ngẫu nhiên (hạt giống cố định nên chạy lại ra đúng các buổi đó). Mỗi bất biến
// là một điều KHÔNG BAO GIỜ được sai, bất kể dữ liệu ra sao: tiền sân chia ra
// phải cộng lại đúng bằng tiền sân, chỉ người giữ chỗ mới bị trừ tiền sân...
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/settlement.dart';

const _ids = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
const _drinks = {'n1': 12000, 'n2': 15000};

Session _random(Random r, {String id = 's', SessionStatus? status}) {
  T pick<T>(List<T> xs) => xs[r.nextInt(xs.length)];
  final votes = <String, bool>{};
  final times = <String, DateTime>{};
  final comp = <String, int>{};
  final playerIds = <String>[];
  for (final p in _ids) {
    final roll = r.nextInt(4);
    if (roll == 1) votes[p] = true;
    if (roll == 2) votes[p] = false;
    if (votes.containsKey(p) && r.nextInt(5) > 0) {
      times[p] = DateTime(2026, 11, 1, 8, r.nextInt(600));
    }
    if (r.nextInt(3) == 0) playerIds.add(p);
    if (r.nextInt(3) == 0) comp[p] = 1 + r.nextInt(3);
  }
  playerIds.shuffle(r);
  final drinks = <String, Map<String, int>>{};
  for (final p in _ids) {
    for (final who in [p, '$p#1', '$p#2', '$p#3']) {
      if (r.nextInt(6) != 0) continue;
      drinks[who] = {
        for (final d in _drinks.keys)
          if (r.nextBool()) d: 1 + r.nextInt(3),
      }..removeWhere((_, v) => v <= 0);
    }
  }
  return Session(
    id: id,
    title: id,
    date: DateTime(2026, 11, 5 + r.nextInt(10), 18),
    courtFee: pick([0, 100000, 300000, 450000, 1000003, 777777]),
    status: status ?? (r.nextBool() ? SessionStatus.voting : SessionStatus.closed),
    votes: votes,
    voteTimes: times,
    playerIds: playerIds,
    companions: comp,
    guestCount: pick([0, 0, 0, 1, 2, 3]),
    maxPlayers: r.nextInt(3) == 0 ? null : 1 + r.nextInt(10),
    drinks: drinks,
    drinkPrices: _drinks,
    createdAt: DateTime(2026, 10, 1),
  );
}

int _sum(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);

void main() {
  final r = Random(20261103);
  final cases = [for (var i = 0; i < 4000; i++) _random(r, id: 's$i')];

  test('đếm suất: người giữ chỗ không trùng, khớp holdsSeat, đã chốt = danh sách chơi', () {
    for (final s in cases) {
      final h = s.seatHolders;
      expect(h.toSet().length, h.length, reason: '${s.id}: trùng người');
      for (final p in _ids) {
        expect(s.holdsSeat(p), h.contains(p), reason: '${s.id}/$p');
      }
      if (s.status == SessionStatus.closed) expect(h, s.playerIds);
      // Đang vote: người đã báo "không" thì không bao giờ giữ chỗ.
      if (s.status == SessionStatus.voting) {
        for (final e in s.votes.entries.where((e) => !e.value)) {
          expect(h.contains(e.key), isFalse, reason: '${s.id}: ${e.key} báo không mà vẫn giữ chỗ');
        }
      }
      expect(s.seatsTaken, h.fold<int>(0, (n, p) => n + 1 + s.companionsOf(p)));
    }
  });

  test('chốt: không vượt giới hạn, chỉ lấy người giữ chỗ, giữ thứ tự ưu tiên', () {
    for (final s in cases.where((s) => s.status == SessionStatus.voting)) {
      final ids = s.playersForClosing();
      final h = s.seatHolders;
      expect(ids, h.take(ids.length).toList(), reason: '${s.id}: phải là phần đầu danh sách giữ chỗ');
      final closed = s.copyWith(
          status: SessionStatus.closed, playerIds: ids, companions: s.companionsForClosing(ids));
      if (s.maxPlayers != null) {
        expect(closed.seatsTaken, lessThanOrEqualTo(s.maxPlayers!), reason: '${s.id}: vượt giới hạn');
        // Còn chỗ thì không được cắt ai.
        if (s.seatsTaken <= s.maxPlayers!) expect(closed.seatsTaken, s.seatsTaken, reason: s.id);
      } else {
        expect(ids, h);
        expect(closed.seatsTaken, s.seatsTaken);
      }
    }
  });

  test('tiền sân: cộng lại đúng bằng tiền sân, chỉ người giữ chỗ bị trừ, chia theo suất', () {
    for (final s in cases) {
      for (final fund in [0, 50000, 300000, 2000000, -100000]) {
        final b = s.pruneCompanionDrinks();
        final st = Settlement.computeSession(session: b, commonFundAvailable: fund);
        expect(st.participants, s.seatsTaken + s.guestCount, reason: s.id);
        final court = _sum(st.courtPerPlayer);
        for (final v in [...st.courtPerPlayer.values, st.commonUsed, st.guestCash]) {
          expect(v, greaterThanOrEqualTo(0), reason: '${s.id}: số âm');
        }
        if (s.courtFee <= 0 || st.participants == 0) {
          expect(court + st.commonUsed + st.guestCash, 0, reason: s.id);
          continue;
        }
        expect(court + st.commonUsed + st.guestCash, s.courtFee,
            reason: '${s.id}: tiền sân chia ra không cộng lại đúng');
        expect(st.commonUsed, lessThanOrEqualTo(max(fund, 0)), reason: '${s.id}: quỹ chung trả quá số có');
        for (final p in st.courtPerPlayer.keys) {
          expect(s.holdsSeat(p), isTrue, reason: '${s.id}: $p không giữ chỗ mà bị trừ tiền sân');
        }
        // Chia theo suất: người kèm N người trả gần đúng N+1 phần (lệch tối đa N+1 đồng do làm tròn).
        final units = s.seatsTaken;
        if (units > 0 && court > 0) {
          for (final e in st.courtPerPlayer.entries) {
            final u = 1 + s.companionsOf(e.key);
            expect((e.value * units - court * u).abs(), lessThanOrEqualTo(u * units),
                reason: '${s.id}: ${e.key} trả ${e.value} không đúng $u suất');
          }
        }
      }
    }
  });

  test('tiền nước: đúng số lượng × giá, nước của người đính kèm tính vào người vote', () {
    for (final s in cases) {
      final b = s.pruneCompanionDrinks();
      final st = Settlement.computeSession(session: b, commonFundAvailable: 0);
      final want = <String, int>{};
      s.drinks.forEach((who, items) {
        final host = Session.hostOf(who);
        // Người đính kèm không còn tồn tại thì nước của họ phải bị bỏ.
        if (Session.isCompanionId(who) && Session.companionIndex(who) > s.companionsOf(host)) return;
        final sum = items.entries.fold<int>(0, (a, e) => a + e.value * _drinks[e.key]!);
        if (sum > 0) want[host] = (want[host] ?? 0) + sum;
      });
      expect(st.drinkPerPlayer, want, reason: s.id);
    }
  });

  test('số dự kiến lúc đang vote = đúng số sẽ trừ nếu chốt ngay bây giờ', () {
    for (final s in cases.where((s) => s.status == SessionStatus.voting)) {
      final ids = s.playersForClosing();
      final closed = s.copyWith(
          status: SessionStatus.closed, playerIds: ids, companions: s.companionsForClosing(ids));
      final atClose = Settlement.computeSession(
          session: closed.pruneCompanionDrinks(), commonFundAvailable: 300000);
      final ledger = [
        LedgerEntry(id: '', playerId: null, amount: 300000, type: LedgerType.commonIn,
            date: DateTime(2026), createdAt: DateTime(2026)),
      ];
      final est = Settlement.estimate(session: s, sessions: [s], ledger: ledger);
      expect(est.participants, atClose.participants, reason: '${s.id}: số người');
      expect(est.courtPerPlayer, atClose.courtPerPlayer, reason: '${s.id}: tiền sân từng người');
      expect(est.drinkPerPlayer, atClose.drinkPerPlayer, reason: '${s.id}: tiền nước');
      expect(est.commonUsed, atClose.commonUsed, reason: s.id);
    }
  });

  test('nhiều buổi cùng mở: tổng quỹ chung dự kiến không vượt số quỹ đang có', () {
    for (var i = 0; i + 3 <= cases.length; i += 3) {
      final open = [
        for (final s in cases.sublist(i, i + 3)) s.copyWith(status: SessionStatus.voting),
      ];
      final ledger = [
        LedgerEntry(id: '', playerId: null, amount: 250000 * (i % 5), type: LedgerType.commonIn,
            date: DateTime(2026), createdAt: DateTime(2026)),
      ];
      final used = open.fold<int>(0, (a, s) =>
          a + Settlement.estimate(session: s, sessions: open, ledger: ledger).commonUsed);
      expect(used, lessThanOrEqualTo(250000 * (i % 5)), reason: 'nhóm $i');
    }
  });

  test('quỹ chung dành cho buổi và số dư sau buổi khớp với số dự kiến', () {
    LedgerEntry row(String? pid, int amount, {String? ref}) => LedgerEntry(
        id: '', playerId: pid, amount: amount,
        type: pid == null ? LedgerType.commonIn : LedgerType.deposit,
        refId: ref, date: DateTime(2026), createdAt: DateTime(2026));
    for (var i = 0; i + 3 <= cases.length; i += 3) {
      final group = cases.sublist(i, i + 3);
      final ledger = [
        row(null, 200000 * (i % 4)),
        for (final p in _ids) row(p, 100000 * (i % 3)),
        // Dòng của một buổi đã chốt trước (nay có thể đang mở lại vote).
        row(null, -150000, ref: group.first.id),
        row('a', -80000, ref: group.first.id),
      ];
      final open = group.where((s) => s.status == SessionStatus.voting).toList()
        ..sort((a, b) {
          final c = a.date.compareTo(b.date);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      final openIds = {for (final s in open) s.id};
      for (final s in group) {
        final est = Settlement.estimate(session: s, sessions: group, ledger: ledger);
        final fund = Settlement.commonFundFor(session: s, sessions: group, ledger: ledger);
        if (s.status == SessionStatus.voting && s.courtFee > 0 && est.participants > 0) {
          final team = s.courtFee - est.guestCash;
          expect(est.commonUsed, max(0, min(fund, team)), reason: '${s.id}: quỹ chung');
        }
        for (final p in _ids) {
          final got = Settlement.balanceAfter(session: s, playerId: p, sessions: group, ledger: ledger);
          if (s.status == SessionStatus.closed) {
            expect(got, ledger.where((e) => e.playerId == p).fold<int>(0, (a, e) => a + e.amount));
            continue;
          }
          // Số dư không tính dòng của buổi đang mở, trừ dự kiến các buổi mở tới buổi này.
          var want = ledger
              .where((e) => e.playerId == p && !openIds.contains(e.refId))
              .fold<int>(0, (a, e) => a + e.amount);
          for (final x in open) {
            final e = Settlement.estimate(session: x, sessions: group, ledger: ledger);
            want -= (e.courtPerPlayer[p] ?? 0) + (e.drinkPerPlayer[p] ?? 0);
            if (x.id == s.id) break;
          }
          expect(got, want, reason: '${s.id}/$p: số dư sau buổi');
        }
      }
    }
  });

  test('ví dụ: đi cả hai buổi đang mở thì số dư sau buổi thứ hai trừ cả hai', () {
    Session open(String id, int day) => Session(
        id: id, title: id, date: DateTime(2026, 11, day), courtFee: 200000,
        votes: const {'a': true, 'b': true}, createdAt: DateTime(2026, 10, 1));
    final b1 = open('b1', 3), b2 = open('b2', 6);
    final ledger = [
      LedgerEntry(id: '', playerId: 'a', amount: 500000, type: LedgerType.deposit,
          date: DateTime(2026), createdAt: DateTime(2026)),
    ];
    final all = [b2, b1];
    expect(Settlement.balanceAfter(session: b1, playerId: 'a', sessions: all, ledger: ledger), 400000);
    expect(Settlement.balanceAfter(session: b2, playerId: 'a', sessions: all, ledger: ledger), 300000);
  });

  test('mở lại vote: ai đang trong danh sách chốt vẫn giữ chỗ', () {
    for (final s in cases.where((s) => s.status == SessionStatus.closed)) {
      final o = s.reopened(code: 1);
      for (final p in s.playerIds) {
        expect(o.holdsSeat(p), isTrue, reason: '${s.id}/$p');
      }
    }
  });
}
