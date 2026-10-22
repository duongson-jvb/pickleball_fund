// Test tích hợp toàn bộ luồng nghiệp vụ trên Firestore giả lập
// (fake_cloud_firestore): người chơi, nộp quỹ, quỹ chung, buổi chơi,
// tiền sân, tiền nước, chi phí, cảnh báo, vote Zalo qua hộp thư webhook.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/team_repository.dart';
import 'package:pickleball_fund/services/team_store.dart';
import 'package:pickleball_fund/services/zalo_bot_service.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

const teamId = 'test-team-01';

Future<void> settle() async {
  // Cho các stream của Firestore giả lập kịp phát dữ liệu.
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<({TeamRepository repo, TeamStore store})> boot() async {
  final db = FakeFirebaseFirestore();
  final repo = TeamRepository(teamId, firestore: db);
  await repo.ensureTeam('Team Test');
  final store = TeamStore(repo);
  await settle();
  expect(store.isReady, isTrue);
  return (repo: repo, store: store);
}

Future<Map<String, String>> addPlayers(TeamRepository repo, TeamStore store, List<String> names) async {
  for (final n in names) {
    await repo.addPlayer(n);
  }
  await settle();
  return {for (final p in store.players) p.name: p.id};
}

Session newSession({required String id, int courtFee = 0, List<String> players = const []}) =>
    Session(
      id: id,
      title: 'Buổi test',
      date: DateTime(2026, 10, 25, 18),
      courtFee: courtFee,
      playerIds: players,
      status: SessionStatus.closed,
      createdAt: DateTime(2026, 10, 21),
    );

void main() {
  group('Người chơi & nộp quỹ', () {
    test('thêm / sửa / xoá người chơi', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An', 'Bình']);
      expect(store.players.length, 2);

      await repo.updatePlayer(ids['An']!, {'name': 'An Nguyễn', 'active': false});
      await settle();
      expect(store.playerById(ids['An']!)!.name, 'An Nguyễn');
      expect(store.activePlayers.length, 1);

      await repo.deposit(playerId: ids['Bình']!, amount: 100000);
      await settle();
      await repo.deletePlayer(ids['Bình']!);
      await settle();
      expect(store.players.length, 1);
      expect(store.ledger, isEmpty, reason: 'xoá người thì xoá luôn sổ quỹ của người đó');
    });

    test('nộp quỹ một người và nộp chia đều cho tất cả', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An', 'Bình', 'Chi']);

      await repo.deposit(playerId: ids['An']!, amount: 200000, note: 'CK');
      await repo.depositForAll(
          amount: 100000, playerIds: store.activePlayers.map((p) => p.id).toList());
      await settle();

      expect(store.balanceOf(ids['An']!), 200000 + 33334);
      expect(store.balanceOf(ids['Bình']!), 33333);
      expect(store.balanceOf(ids['Chi']!), 33333);
      expect(store.totalPlayerBalance, 300000);
    });

    test('cảnh báo sắp hết quỹ dưới ngưỡng (mặc định 50k)', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An', 'Bình']);
      await repo.deposit(playerId: ids['An']!, amount: 49999);
      await repo.deposit(playerId: ids['Bình']!, amount: 50000);
      await settle();
      expect(store.lowBalancePlayers.map((p) => p.name), ['An']);

      await repo.updateSettings({'lowBalanceThreshold': 60000});
      await settle();
      expect(store.lowBalancePlayers.length, 2);
    });
  });

  group('Buổi chơi', () {
    test('tiền sân: ưu tiên quỹ chung, thiếu chia đều; sửa số người thì tính lại', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An', 'Bình', 'Chi', 'Dũng']);
      for (final id in ids.values) {
        await repo.deposit(playerId: id, amount: 200000);
      }
      await repo.addCommonFund(amount: 100000);
      await settle();
      expect(store.commonFund, 100000);

      final sid = await repo.createSession(newSession(id: '', courtFee: 400000));
      await settle();
      var s = store.sessions.single.copyWith(playerIds: [ids['An']!, ids['Bình']!]);
      await repo.saveAndSettleSession(s);
      await settle();

      // 400k, 2 người → quỹ chung trả 100k, còn 300k chia đôi.
      expect(store.commonFund, 0);
      expect(store.balanceOf(ids['An']!), 200000 - 150000);
      expect(store.balanceOf(ids['Bình']!), 50000);
      expect(store.balanceOf(ids['Chi']!), 200000);

      // Thêm 2 người nữa (không vote nhưng vẫn đi) → tính lại, không ghi trùng.
      s = store.sessions.single.copyWith(playerIds: ids.values.toList());
      await repo.saveAndSettleSession(s);
      await settle();
      expect(store.commonFund, 0);
      for (final id in ids.values) {
        expect(store.balanceOf(id), 200000 - 75000);
      }
      expect(store.ledger.where((e) => e.refId == sid).length, 1 + 4,
          reason: '1 dòng quỹ chung + 4 dòng tiền sân, không trùng');

      // Xoá buổi → hoàn tiền.
      await repo.deleteSession(sid);
      await settle();
      expect(store.commonFund, 100000);
      expect(store.balanceOf(ids['An']!), 200000);
    });

    test('khách trả tiền mặt, không trừ quỹ ai', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An', 'Bình']);
      final sid = await repo.createSession(
          newSession(id: '', courtFee: 300000, players: ids.values.toList()));
      await settle();
      final s = store.sessions.single.copyWith(guestCount: 1);
      await repo.saveAndSettleSession(s);
      await settle();
      final st = store.sessions.single.settlement;
      expect(st.perHead, 100000);
      expect(st.guestCash, 100000);
      expect(store.balanceOf(ids['An']!), -100000);
      expect(store.ledger.where((e) => e.refId == sid).length, 2);
    });

    test('tiền nước: theo số lượng × giá buổi, giá mặc định theo ngày sửa gần nhất', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An', 'Bình']);
      await repo.addDrinkType('Revive', 15000);
      await settle();
      final revive = store.drinkTypes.single;
      // Đổi giá từ 1/11: buổi 25/10 vẫn dùng 15k, buổi 5/11 dùng 18k.
      await repo.setDrinkPrice(revive, DateTime(2026, 11, 1), 18000);
      await settle();
      expect(store.defaultDrinkPrices(DateTime(2026, 10, 25))[revive.id], 15000);
      expect(store.defaultDrinkPrices(DateTime(2026, 11, 5))[revive.id], 18000);

      final sid = await repo.createSession(newSession(id: '', players: ids.values.toList())
          .copyWith(drinkPrices: store.defaultDrinkPrices(DateTime(2026, 10, 25))));
      await settle();
      final s = store.sessions.single.copyWith(drinks: {
        ids['An']!: {revive.id: 2},
      });
      await repo.saveAndSettleSession(s);
      await settle();
      expect(store.balanceOf(ids['An']!), -30000);
      expect(store.balanceOf(ids['Bình']!), 0);
      expect(store.sessions.single.settlement.totalDrinks, 30000);

      // Sửa giá riêng của buổi → tính lại.
      final s2 = store.sessions.single.copyWith(drinkPrices: {revive.id: 20000});
      await repo.saveAndSettleSession(s2);
      await settle();
      expect(store.balanceOf(ids['An']!), -40000);
      expect(store.ledger.where((e) => e.refId == sid && e.type == LedgerType.drink).length, 1);
    });

    test('lưu đồng thời nhiều lần cho cùng buổi không tạo dòng trùng', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An', 'Bình']);
      final sid = await repo.createSession(
          newSession(id: '', courtFee: 200000, players: ids.values.toList()));
      await settle();
      final base = store.sessions.single;
      // 5 lần lưu gần như cùng lúc (giống bấm +1 liên tục).
      await Future.wait([
        for (var i = 1; i <= 5; i++)
          repo.saveAndSettleSession(base.copyWith(guestCount: i)),
      ]);
      await settle();
      expect(store.ledger.where((e) => e.refId == sid).length, 2);
      expect(store.sessions.single.guestCount, 5);
    });
  });

  group('Chi phí khác', () {
    test('không chọn ai: chia tất cả, ưu tiên quỹ chung; chọn người: chia riêng', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An', 'Bình', 'Chi']);
      await repo.addCommonFund(amount: 50000);
      await settle();

      await repo.saveAndSettleExpense(
        Expense(id: '', title: 'Mua bóng', amount: 200000, date: DateTime(2026), createdAt: DateTime(2026)),
      );
      await settle();
      expect(store.commonFund, 0);
      expect(store.balanceOf(ids['An']!), -50000);
      expect(store.expenses.single.commonUsed, 50000);

      await repo.saveAndSettleExpense(
        Expense(
            id: '', title: 'Áo', amount: 300000, playerIds: [ids['An']!, ids['Bình']!],
            date: DateTime(2026), createdAt: DateTime(2026)),
      );
      await settle();
      expect(store.balanceOf(ids['An']!), -200000);
      expect(store.balanceOf(ids['Chi']!), -50000);

      // Sửa chi phí → tính lại, xoá chi phí → hoàn tiền.
      final e = store.expenses.firstWhere((x) => x.title == 'Áo');
      await repo.saveAndSettleExpense(e.copyWith(amount: 100000));
      await settle();
      expect(store.balanceOf(ids['An']!), -100000);
      await repo.deleteExpense(e.id);
      await settle();
      expect(store.balanceOf(ids['An']!), -50000);
    });
  });

  group('Vote Zalo qua hộp thư webhook', () {
    test('tin trong zaloInbox được biến thành vote và xoá khỏi hộp thư', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['Nguyễn Văn An', 'Bình']);
      await repo.updateSettings({'zaloBotToken': 'x:y', 'zaloBotName': 'Bot Test', 'zaloGroupId': 'g1'});
      await repo.createSession(newSession(id: '').copyWith(status: SessionStatus.voting));
      await settle();

      Future<void> inbox(String id, String from, String name, String text, {String chat = 'g1', String type = 'GROUP'}) =>
          repo.zaloInbox.doc(id).set({
            'eventName': 'message.text.received',
            'messageId': id,
            'fromId': from,
            'fromName': name,
            'chatId': chat,
            'chatType': type,
            'text': text,
            'date': DateTime.now(),
          });

      await inbox('m1', 'z-an', 'An', '1');
      await inbox('m2', 'z-binh', 'binh', '@Bot Test không đi');
      await inbox('m3', 'z-la', 'Người Lạ', 'đi'); // chưa có trong DB → tự thêm
      await inbox('m3b', 'z-la', 'Người Lạ', '1'); // cùng người, cùng đợt → không tạo trùng
      await inbox('m5', 'z-hoi', 'Người Hỏi', 'mấy giờ vậy?'); // không rõ → chờ gán
      await inbox('m4', 'z-other', 'Ai đó', '1', chat: 'g-khac'); // ngoài nhóm → bỏ qua
      await settle();
      await settle();

      final s = store.sessions.single;
      expect(s.votes[ids['Nguyễn Văn An']!], isTrue);
      expect(s.votes[ids['Bình']!], isFalse);
      expect(store.playerById(ids['Nguyễn Văn An']!)!.zaloId, 'z-an', reason: 'nhớ Zalo id');

      // Người lạ reply vote → tự tạo người chơi, có vote, nhớ Zalo id, không tạo trùng.
      final la = store.players.where((p) => p.zaloId == 'z-la').toList();
      expect(la.length, 1, reason: 'chỉ tạo một người cho cùng Zalo id');
      expect(la.single.name, 'Người Lạ');
      expect(la.single.active, isTrue);
      expect(s.votes[la.single.id], isTrue);
      expect(store.players.length, 3);

      // Tin không rõ nghĩa từ người lạ → vẫn chờ gán, không tự tạo.
      expect(s.zaloPending.map((p) => p.name), ['Người Hỏi']);
      expect(store.settings.zaloChats.keys, containsAll(['g1', 'g-khac']));
      final remaining = await repo.zaloInbox.get();
      expect(remaining.docs, isEmpty, reason: 'đã xử lý thì xoá hộp thư');

      // Gán tay tin chờ → vote, nhớ id.
      await ZaloVoteSync.resolvePending(store, store.sessions.single, s.zaloPending.single,
          store.playerById(ids['Bình']!)!, voteOverride: true);
      await settle();
      expect(store.sessions.single.zaloPending, isEmpty);
      expect(store.sessions.single.votes[ids['Bình']!], isTrue);
      expect(store.playerById(ids['Bình']!)!.zaloId, 'z-hoi');

      // Lần sau cùng người lạ reply → khớp theo Zalo id đã lưu, không tạo thêm.
      await inbox('m6', 'z-la', 'Tên Mới Đổi', '0');
      await settle();
      await settle();
      expect(store.players.length, 3);
      expect(store.sessions.single.votes[la.single.id], isFalse);
    });

    test('chưa có buổi vote: tin vote bị bỏ qua và xoá, không tính về sau', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An']);
      await repo.updateSettings({'zaloBotToken': 'x:y'});
      await repo.zaloInbox.doc('v1').set({
        'messageId': 'v1', 'fromId': 'z1', 'fromName': 'An', 'chatId': 'g1',
        'chatType': 'GROUP', 'text': '1', 'date': DateTime.now(),
      });
      await settle();
      await settle();
      expect((await repo.zaloInbox.get()).docs, isEmpty, reason: 'không giữ lại');
      expect(store.settings.zaloChats.keys, ['g1'], reason: 'vẫn nhớ nhóm để chọn');

      // Tạo buổi vote sau đó → tin cũ KHÔNG được tính.
      await repo.createSession(newSession(id: '').copyWith(status: SessionStatus.voting));
      await settle();
      await settle();
      expect(store.sessions.single.votes, isEmpty);
      expect(store.playerById(ids['An']!)!.zaloId, '', reason: 'không khớp/nhớ id từ tin cũ');
    });

    test('chỉ nhận tin gửi sau khi tạo buổi chơi', () async {
      final (:repo, :store) = await boot();
      final ids = await addPlayers(repo, store, ['An', 'Bình']);
      await repo.updateSettings({'zaloBotToken': 'x:y'});
      final now = DateTime.now();
      await repo.createSession(Session(
        id: '', title: 'Vote', date: now.add(const Duration(days: 1)),
        status: SessionStatus.voting, createdAt: now,
      ));
      await settle();
      // Tin gửi 10 phút TRƯỚC khi tạo buổi → bỏ qua; tin gửi SAU → nhận.
      await repo.zaloInbox.doc('old').set({
        'messageId': 'old', 'fromId': 'z-an', 'fromName': 'An', 'chatId': 'g1',
        'chatType': 'GROUP', 'text': '1', 'date': now.subtract(const Duration(minutes: 10)),
      });
      await repo.zaloInbox.doc('new').set({
        'messageId': 'new', 'fromId': 'z-binh', 'fromName': 'Bình', 'chatId': 'g1',
        'chatType': 'GROUP', 'text': '1', 'date': now.add(const Duration(seconds: 5)),
      });
      await settle();
      await settle();
      final votes = store.sessions.single.votes;
      expect(votes.containsKey(ids['An']!), isFalse);
      expect(votes[ids['Bình']!], isTrue);
      expect((await repo.zaloInbox.get()).docs, isEmpty);
    });

    test('ZaloUpdate.fromInboxDoc đọc Timestamp của Firestore', () async {
      final (:repo, :store) = await boot();
      await repo.zaloInbox.doc('t').set({'chatId': 'c', 'date': DateTime(2026, 1, 2)});
      final d = await repo.zaloInbox.doc('t').get();
      final u = ZaloUpdate.fromInboxDoc(d.id, d.data()!);
      expect(u!.date.year, 2026);
      store.dispose();
    });
  });
}
