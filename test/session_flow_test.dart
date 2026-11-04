// Chuỗi thao tác ngẫu nhiên đan xen giữa mọi bên ghi vào một buổi chơi:
// vote qua Zalo / bấm trong app của thành viên (chỉ ghi được vote khi đang
// vote), quản lý tích / bỏ tích, đổi số người đính kèm, chốt, mở lại vote, ghi
// nước, xoá người chơi. Sau MỖI bước, danh sách người đi và tiền phải khớp với
// "sự thật" tính độc lập: câu trả lời mới nhất của mỗi người.
//
// Đây là họ lỗi đã gặp thật: hai nơi cùng nói "ai đi" mà một bên ghi không tới
// (mở lại vote rồi nhắn "0" vẫn bị trừ tiền vì danh sách chơi không đổi).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/settlement.dart';

const _people = ['a', 'b', 'c', 'd', 'e'];

/// Vote qua Zalo / bấm trong app của thành viên: rules chỉ cho ghi votes,
/// voteTimes, companions của buổi đang vote (webhook và setVote ghi y hệt).
Session _memberAnswer(Session s, String p, bool going, int seats, DateTime at) {
  if (s.status != SessionStatus.voting) return s; // rules từ chối
  final comp = {...s.companions};
  if (going && seats > 1) {
    comp[p] = seats - 1;
  } else {
    comp.remove(p);
  }
  return s.copyWith(votes: {...s.votes, p: going}, voteTimes: {...s.voteTimes, p: at}, companions: comp);
}

void main() {
  for (final withMax in [false, true]) {
    test('chuỗi thao tác ngẫu nhiên${withMax ? ' (có giới hạn suất)' : ''}', () {
      final r = Random(withMax ? 777 : 2026);
      var steps = 0;
      for (var run = 0; run < 1500; run++) {
        var s = Session(
          id: 's', title: 's', date: DateTime(2026, 11, 20), courtFee: 300000 + r.nextInt(5) * 1001,
          maxPlayers: withMax ? 2 + r.nextInt(5) : null, createdAt: DateTime(2026, 11, 1),
        );
        // Sự thật: ai đi (theo câu trả lời mới nhất) và số người đính kèm.
        final going = <String>{};
        final comp = <String, int>{};
        var clock = DateTime(2026, 11, 2);
        final log = <String>[];

        for (var i = 0; i < 40; i++) {
          steps++;
          clock = clock.add(Duration(minutes: 1 + r.nextInt(30)));
          final p = _people[r.nextInt(_people.length)];
          final op = r.nextInt(9);
          final before = s.status;
          switch (op) {
            case 0 || 1: // vote qua Zalo / app thành viên
              final yes = r.nextBool();
              final seats = yes ? 1 + r.nextInt(3) : 0;
              log.add('member $p ${yes ? seats : 0}');
              s = _memberAnswer(s, p, yes, seats, clock);
              if (before == SessionStatus.voting) {
                if (yes) {
                  going.add(p);
                  if (seats > 1) {
                    comp[p] = seats - 1;
                  } else {
                    comp.remove(p);
                  }
                } else {
                  going.remove(p);
                  comp.remove(p);
                }
              }
            case 2 || 3: // quản lý tích / bỏ tích
              final yes = r.nextBool();
              log.add('admin $p $yes');
              s = s.withAdminAnswer(p, yes, clock);
              if (yes) {
                going.add(p);
              } else {
                going.remove(p);
                comp.remove(p);
              }
            case 4: // quản lý đổi số người đính kèm (nút +/- chỉ hiện với người đi)
              if (!s.holdsSeat(p)) break;
              final n = r.nextInt(3);
              log.add('companions $p $n');
              final c = {...s.companions};
              if (n > 0) {
                c[p] = n;
              } else {
                c.remove(p);
              }
              s = s.copyWith(companions: c);
              if (n > 0) {
                comp[p] = n;
              } else {
                comp.remove(p);
              }
            case 5: // chốt
              if (s.status != SessionStatus.voting) break;
              log.add('close');
              final before = s;
              s = s.asClosed();
              if (s.maxPlayers != null) {
                // Có giới hạn: người bị cắt không còn đi, đính kèm bị giảm.
                going
                  ..clear()
                  ..addAll(s.playerIds);
                comp
                  ..clear()
                  ..addAll(s.companions);
                expect(s.playerIds, before.seatHolders.take(s.playerIds.length).toList(),
                    reason: 'chốt phải giữ thứ tự ưu tiên · ${log.join(' → ')}');
              }
            case 6: // mở lại vote
              if (s.status != SessionStatus.closed) break;
              log.add('reopen');
              s = s.reopened(code: 1);
            case 7: // ghi nước cho người đó hoặc người đính kèm của họ
              final who = r.nextBool() ? p : '$p#${1 + r.nextInt(2)}';
              log.add('drink $who');
              s = s.copyWith(
                drinks: {
                  ...s.drinks,
                  who: {'n1': 1 + r.nextInt(3)},
                },
                drinkPrices: const {'n1': 12000},
              );
            case 8: // xoá người chơi
              if (r.nextInt(4) != 0) break;
              log.add('delete $p');
              s = s.withoutPlayer(p);
              going.remove(p);
              comp.remove(p);
          }

          final trace = log.join(' → ');
          // 1. Danh sách người đi = sự thật.
          expect(s.seatHolders.toSet(), going, reason: 'danh sách lệch · $trace');
          // 2. Người đính kèm của người đi = sự thật.
          for (final x in going) {
            expect(s.companionsOf(x), comp[x] ?? 0, reason: 'đính kèm của $x lệch · $trace');
          }
          // 3. Tiền: tính như lúc chốt (đã chốt: chính nó; đang vote: dự kiến).
          final billed = s.asClosed();
          final st = Settlement.computeSession(session: billed.pruneCompanionDrinks(), commonFundAvailable: 0);
          for (final x in st.courtPerPlayer.keys) {
            expect(billed.holdsSeat(x), isTrue, reason: '$x không đi mà bị trừ tiền sân · $trace');
            expect(going.contains(x), isTrue, reason: '$x đã báo không đi mà bị trừ tiền sân · $trace');
          }
          if (billed.seatsTaken > 0) {
            expect(st.courtPerPlayer.values.fold<int>(0, (a, b) => a + b), s.courtFee,
                reason: 'tiền sân chia ra không cộng lại đúng · $trace');
          }
          if (s.maxPlayers != null && s.status == SessionStatus.closed) {
            // Đã chốt thì chỉ quản lý thêm người được (cố ý), còn chốt không vượt.
            expect(going, s.playerIds.toSet(), reason: trace);
          }
          // 4. Nước của người đính kèm không còn tồn tại không được tính.
          for (final x in st.drinkPerPlayer.keys) {
            expect(Session.isCompanionId(x), isFalse, reason: trace);
          }
          final pruned = billed.pruneCompanionDrinks();
          for (final k in pruned.drinks.keys.where(Session.isCompanionId)) {
            expect(Session.companionIndex(k) <= pruned.companionsOf(Session.hostOf(k)), isTrue,
                reason: 'nước của $k còn tính dù người đính kèm không còn · $trace');
          }
          // 5. Sổ quỹ: chỉ buổi đã chốt mới có tiền; đang vote thì dự kiến = số
          //    sẽ trừ nếu chốt ngay (cùng phép tính).
          if (s.status == SessionStatus.voting) {
            final est = Settlement.estimate(session: s, sessions: [s], ledger: const []);
            expect(est.courtPerPlayer, st.courtPerPlayer, reason: 'dự kiến lệch số sẽ trừ · $trace');
          }
        }
      }
      // ignore: avoid_print
      print('đã chạy $steps bước');
    });
  }
}
