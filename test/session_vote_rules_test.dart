import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/team_repository.dart';
import 'package:pickleball_fund/services/team_store.dart';
import 'package:pickleball_fund/services/zalo_bot_service.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

ZaloUpdate upd(String id, String from, String name, String text, DateTime at) => ZaloUpdate(
      eventName: 'message.text.received',
      messageId: id,
      fromId: from,
      fromName: name,
      chatId: 'g1',
      chatType: 'GROUP',
      text: text,
      date: at,
    );

void main() {
  group('Session: hạn vote & giới hạn', () {
    test('hạn vote mặc định = giờ chơi; đặt riêng thì dùng giá trị đó', () {
      final start = DateTime(2026, 11, 1, 18);
      final s = Session(id: 's', title: '', date: start, createdAt: DateTime(2026, 10, 30));
      expect(s.effectiveVoteDeadline, start);
      final s2 = s.copyWith(voteDeadline: DateTime(2026, 11, 1, 12));
      expect(s2.effectiveVoteDeadline, DateTime(2026, 11, 1, 12));
      expect(s2.copyWith(clearVoteDeadline: true).voteDeadline, isNull);
    });

    test('isFull theo số vote đi và maxPlayers', () {
      final s = Session(
        id: 's', title: '', date: DateTime(2027), createdAt: DateTime(2026),
        maxPlayers: 2, votes: const {'a': true, 'b': true, 'c': false},
      );
      expect(s.isFull, isTrue);
      expect(s.copyWith(clearMaxPlayers: true).isFull, isFalse);
      expect(s.copyWith(maxPlayers: 3).isFull, isFalse);
    });

    test('toMap/fromDoc giữ các trường mới', () async {
      final db = FakeFirebaseFirestore();
      final repo = TeamRepository('t-rules-01', firestore: db);
      final id = await repo.createSession(Session(
        id: '', title: 'X', date: DateTime(2026, 11, 1, 18),
        createdByName: 'Sơn', createdById: 'p1',
        voteDeadline: DateTime(2026, 11, 1, 12), maxPlayers: 8,
        createdAt: DateTime(2026, 10, 30),
      ));
      final s = Session.fromDoc(await repo.sessions.doc(id).get());
      expect(s.createdByName, 'Sơn');
      expect(s.createdById, 'p1');
      expect(s.voteDeadline, DateTime(2026, 11, 1, 12));
      expect(s.maxPlayers, 8);
    });
  });

  group('Vote Zalo: hạn vote & giới hạn số người', () {
    test('tin sau hạn bị bỏ qua; đủ người thì không nhận thêm "đi" nhưng vẫn cho đổi ý', () async {
      final db = FakeFirebaseFirestore();
      final repo = TeamRepository('t-rules-02', firestore: db);
      await repo.ensureTeam('T');
      for (final n in ['An', 'Bình', 'Chi']) {
        await repo.addPlayer(n);
      }
      await repo.updateSettings({'zaloBotToken': 'x:y', 'zaloGroupId': 'g1'});
      final store = TeamStore(repo);
      await settle();
      final ids = {for (final p in store.players) p.name: p.id};
      final now = DateTime.now();
      final deadline = now.add(const Duration(hours: 1));
      final sid = await repo.createSession(Session(
        id: '', title: 'V', date: now.add(const Duration(hours: 3)),
        status: SessionStatus.voting, voteDeadline: deadline, maxPlayers: 2,
        createdAt: now.subtract(const Duration(minutes: 5)),
      ));
      await settle();
      final target = store.sessions.firstWhere((s) => s.id == sid);

      final r1 = await ZaloVoteSync.apply(store, [
        upd('1', 'z-an', 'An', '1', now),
        upd('2', 'z-binh', 'Bình', '1', now.add(const Duration(seconds: 1))),
        upd('3', 'z-chi', 'Chi', '1', now.add(const Duration(seconds: 2))), // đủ người → từ chối
        upd('4', 'z-moi', 'Người Mới', 'đi', now.add(const Duration(seconds: 3))), // không tự tạo
        upd('5', 'z-an', 'An', '0', deadline.add(const Duration(minutes: 1))), // trễ hạn
      ], target: target);
      await settle();

      final s = store.sessions.firstWhere((x) => x.id == sid);
      expect(s.votes[ids['An']!], isTrue, reason: 'tin trễ hạn không đổi được vote');
      expect(s.votes[ids['Bình']!], isTrue);
      expect(s.votes.containsKey(ids['Chi']!), isFalse);
      expect(r1.fullNames, ['Chi', 'Người Mới']);
      expect(r1.lateCount, 1);
      expect(store.players.length, 3, reason: 'không tự tạo người khi đã đủ');

      // Người đã "đi" đổi ý sang "không" vẫn được, sau đó Chi vào được.
      await ZaloVoteSync.apply(store, [
        upd('6', 'z-binh', 'Bình', '0', now.add(const Duration(seconds: 10))),
        upd('7', 'z-chi', 'Chi', '1', now.add(const Duration(seconds: 11))),
      ], target: store.sessions.firstWhere((x) => x.id == sid));
      await settle();
      final s2 = store.sessions.firstWhere((x) => x.id == sid);
      expect(s2.votes[ids['Bình']!], isFalse);
      expect(s2.votes[ids['Chi']!], isTrue);
      store.dispose();
    });

    test('hết hạn vote → máy quản trị tự chốt danh sách, cắt theo giới hạn', () async {
      final db = FakeFirebaseFirestore();
      final repo = TeamRepository('t-rules-03', firestore: db);
      await repo.ensureTeam('T');
      for (final n in ['An', 'Bình', 'Chi']) {
        await repo.addPlayer(n);
      }
      final store = TeamStore(repo); // AuthService.none() → coi như quản trị
      await settle();
      final ids = store.players.map((p) => p.id).toList();
      final now = DateTime.now();
      final sid = await repo.createSession(Session(
        id: '', title: 'Hết hạn', date: now.add(const Duration(hours: 2)),
        status: SessionStatus.voting,
        voteDeadline: now.subtract(const Duration(minutes: 1)), // đã quá hạn
        maxPlayers: 2,
        votes: {ids[0]: true, ids[1]: true, ids[2]: true},
        courtFee: 200000,
        createdAt: now.subtract(const Duration(hours: 1)),
      ));
      await settle();
      await settle();
      final s = store.sessions.firstWhere((x) => x.id == sid);
      expect(s.status, SessionStatus.closed);
      expect(s.playerIds.length, 2, reason: 'cắt theo giới hạn 2 người');
      expect(s.settlement.courtPerPlayer.length, 2, reason: 'đã tính tiền sân');
      store.dispose();
    });
  });
}
