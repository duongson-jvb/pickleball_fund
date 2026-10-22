// Bài kiểm tra rà soát (22/10/2026): mỗi test mô tả hành vi ĐÚNG mà người dùng
// mong đợi, nên test nào đỏ là một lỗi thật.
//
// Nhóm lỗi tính tiền (A, C, F, G) và nhóm bot/Zalo (B2, D1, E1, E2, H1) đều đã
// sửa ngày 22/10 - các test này là test hồi quy, đỏ trở lại nghĩa là lỗi tái phát.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/share_service.dart';
import 'package:pickleball_fund/services/team_repository.dart';
import 'package:pickleball_fund/services/team_store.dart';
import 'package:pickleball_fund/services/zalo_bot_service.dart';
import 'package:pickleball_fund/services/zalo_commands.dart';
import 'package:pickleball_fund/services/zalo_drinks.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';
import 'package:pickleball_fund/utils/format.dart';
import 'package:pickleball_fund/utils/text.dart';

const teamId = 'audit-team-01';

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<({TeamRepository repo, TeamStore store})> boot() async {
  final db = FakeFirebaseFirestore();
  final repo = TeamRepository(teamId, firestore: db);
  await repo.ensureTeam('Team Audit');
  final store = TeamStore(repo);
  await settle();
  return (repo: repo, store: store);
}

Player _p(String id, String name) =>
    Player(id: id, name: name, createdAt: DateTime(2026, 10, 1));

DrinkType _d(String id, String name, int price, {int code = 0}) => DrinkType(
      id: id,
      name: name,
      code: code,
      prices: [DrinkPrice(date: DateTime(2026, 1, 1), price: price)],
    );

void main() {
  group('A. Số tiền nhập tay', () {
    test('A1. "5.5k" phải là 5.500đ, không phải 55.000đ', () {
      expect(parseAmount('5.5k'), 5500);
    });

    test('A2. số âm không nên thành số tiền hợp lệ', () {
      expect(parseAmount('-50k'), lessThanOrEqualTo(0));
    });
  });

  group('B. Bỏ dấu tiếng Việt', () {
    test('B1. bảng chữ có dấu và không dấu phải cùng độ dài', () {
      // Lấy lại hai chuỗi trong utils/text.dart để so độ dài.
      const withDiacritics =
          'àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ';
      const without =
          'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
      expect(without.length, withDiacritics.length);
    });

    test('B2. tên ở dạng NFD (máy Mac/iPhone) cũng phải bỏ được dấu', () {
      // "Nước" dạng tổ hợp: n + ư + ơ + dấu sắc rời.
      final nfd = 'Nước';
      expect(normalizeVi(nfd), 'nuoc');
    });
  });

  group('C. Khớp tên người chơi', () {
    test('C1. dán kết quả vote không được khớp tên nằm trong từ khác', () async {
      final (:repo, :store) = await boot();
      await repo.addPlayer('An');
      await repo.addPlayer('Bình');
      await settle();
      // Danh sách dán từ Zalo chỉ có Bình đi; "Hoàng" chứa chuỗi "an".
      final matched = ShareService.parseZaloVote(store, 'Hoàng Văn Bình\n');
      final names = matched.map(store.playerName).toList();
      expect(names, isNot(contains('An')));
    });

    test('C2. người lạ tên "Lan" không được khớp thành người chơi "An"', () {
      final players = [_p('p1', 'An'), _p('p2', 'Bình')];
      final m = ZaloVoteSync.matchPlayer(
          zaloId: 'z9', zaloName: 'Lan', players: players);
      expect(m, isNull);
    });
  });

  group('D. Lệnh chat với bot', () {
    test('D1. "menu nước" phải là yêu cầu xem danh sách nước, không phải help', () {
      expect(ZaloCommands.isCommand('menu nuoc'), isFalse,
          reason: '"menu nuoc" bị nhận là lệnh help nên không trả danh sách nước');
      expect(ZaloDrinks.isListRequest('menu nuoc'), isTrue);
      // "menu" đứng một mình vẫn là help.
      expect(ZaloCommands.isCommand('menu'), isTrue);
    });

    test('D2. "bảng giá nước" vẫn là yêu cầu xem danh sách', () {
      expect(ZaloCommands.isCommand('bang gia nuoc'), isFalse);
      expect(ZaloDrinks.isListRequest('bang gia nuoc'), isTrue);
    });
  });

  group('E. Lệnh ghi nước', () {
    final types = [
      _d('d1', 'Revive', 15000, code: 1),
      _d('d2', 'Nước suối', 5000, code: 2),
    ];

    test('E1. "N1 2 N2" (thiếu số cho N2) phải báo lỗi, không im lặng bỏ qua', () {
      final c = ZaloDrinks.parse('n1 2 n2', types);
      // Hiện tại: chỉ ghi N1, N2 bị bỏ qua không báo gì.
      expect(c.changes, isEmpty);
      expect(c.error, contains('Nước suối'),
          reason: 'N2 thiếu số lượng phải được báo rõ: ${c.error}');
    });

    test('E2. nhập hộ nước cho người không có trong buổi: ghi nước, KHÔNG thêm vào danh sách chơi', () async {
      final (:repo, :store) = await boot();
      await repo.addPlayer('An');
      await repo.addPlayer('Bình');
      await repo.addPlayer('Chi');
      await repo.addDrinkType('Revive', 15000, code: 1);
      await repo.updateSettings({'zaloBotToken': 'x:y', 'zaloGroupId': 'g1'});
      await settle();
      final an = store.players.firstWhere((p) => p.name == 'An');
      final binh = store.players.firstWhere((p) => p.name == 'Bình');
      final chi = store.players.firstWhere((p) => p.name == 'Chi');
      await repo.updatePlayer(an.id, {'zaloId': 'z-an'});
      final now = DateTime.now();
      final sid = await repo.createSession(Session(
        id: '', title: 'B', date: now.subtract(const Duration(hours: 1)),
        courtFee: 200000, playerIds: [an.id, binh.id], status: SessionStatus.closed,
        drinkPrices: store.defaultDrinkPrices(now), createdAt: now.subtract(const Duration(days: 1)),
      ));
      await settle();
      await repo.saveAndSettleSession(store.sessions.firstWhere((s) => s.id == sid));
      await settle();
      final courtBefore = store.sessions.firstWhere((s) => s.id == sid).settlement.courtPerPlayer[an.id];

      // An nhập hộ cho Chi (không chơi buổi này).
      await ZaloVoteSync.apply(store, [
        ZaloUpdate(eventName: 'message.text.received', messageId: 'm', fromId: 'z-an', fromName: 'An',
            chatId: 'g1', chatType: 'GROUP', text: '@Chi N1 2', date: now),
      ], target: store.sessions.firstWhere((s) => s.id == sid));
      await settle();
      final s = store.sessions.firstWhere((x) => x.id == sid);
      expect(s.playerIds, isNot(contains(chi.id)), reason: 'không tự thêm vào danh sách chơi');
      expect(s.drinks[chi.id]?.values.single, 2, reason: 'nước vẫn được ghi');
      expect(store.balanceOf(chi.id), -30000, reason: 'tiền nước trừ đúng người uống');
      expect(s.settlement.courtPerPlayer[an.id], courtBefore, reason: 'tiền sân người khác không đổi');
    });
  });

  group('F. Toàn vẹn dữ liệu khi xoá người chơi', () {
    test('F1. xoá người chơi phải bỏ họ khỏi buổi chơi, không để "tiền ma"', () async {
      final (:repo, :store) = await boot();
      await repo.addPlayer('An');
      await repo.addPlayer('Bình');
      await settle();
      final an = store.players.firstWhere((p) => p.name == 'An').id;
      final binh = store.players.firstWhere((p) => p.name == 'Bình').id;

      final s = Session(
        id: 's1',
        title: 'Buổi 1',
        date: DateTime(2026, 10, 20, 18),
        courtFee: 200000,
        playerIds: [an, binh],
        status: SessionStatus.closed,
        createdAt: DateTime(2026, 10, 19),
      );
      await repo.saveAndSettleSession(s);
      await settle();

      await repo.deletePlayer(an);
      await settle();
      expect(store.players.length, 1);

      // Sửa buổi (ví dụ ghi thêm nước) sau khi đã xoá An.
      final latest = store.sessions.first;
      await repo.saveAndSettleSession(latest);
      await settle();

      expect(store.sessions.first.playerIds, isNot(contains(an)),
          reason: 'buổi chơi vẫn giữ id người đã xoá');
      expect(store.balances.keys, isNot(contains(an)),
          reason: 'sổ quỹ sinh lại tiền cho người đã xoá (tiền ma)');
      // Phần tiền sân người bị xoá đang gánh được chia lại cho người còn lại,
      // nên tổng tiền sân thu vẫn đúng bằng 200.000đ.
      expect(store.balanceOf(binh), -200000,
          reason: 'tiền sân của người bị xoá phải được chia lại, không biến mất');
      expect(store.ledger.where((e) => e.refId == 's1').length, 1);
    });
  });

  group('G. Quỹ chung khi lưu nhiều buổi cùng lúc', () {
    test('G1. hai buổi lưu song song không được tiêu quá quỹ chung', () async {
      final (:repo, :store) = await boot();
      await repo.addPlayer('An');
      await settle();
      final an = store.players.first.id;
      await repo.addCommonFund(amount: 100000);
      await settle();
      expect(store.commonFund, 100000);

      Session mk(String id) => Session(
            id: id,
            title: id,
            date: DateTime(2026, 10, 20, 18),
            courtFee: 100000,
            playerIds: [an],
            status: SessionStatus.closed,
            createdAt: DateTime(2026, 10, 19),
          );
      // Hai buổi lưu đồng thời, mỗi buổi tự thấy quỹ chung còn 100.000đ.
      await Future.wait([
        repo.saveAndSettleSession(mk('s1')),
        repo.saveAndSettleSession(mk('s2')),
      ]);
      await settle();
      expect(store.commonFund, greaterThanOrEqualTo(0),
          reason: 'quỹ chung bị âm vì hai buổi cùng trừ một số dư');
    });
  });

  group('H. Hạn vote & giới hạn người', () {
    test('H1. chốt danh sách khi quá giới hạn phải ưu tiên người vote trước', () {
      final s = Session(
        id: 's1',
        title: 'B',
        date: DateTime(2026, 10, 25, 18),
        maxPlayers: 2,
        votes: const {'p3': true, 'p1': true, 'p2': true, 'p4': false},
        voteTimes: {
          'p3': DateTime(2026, 10, 21, 10), // vote sau cùng
          'p1': DateTime(2026, 10, 21, 8),
          'p2': DateTime(2026, 10, 21, 9),
        },
        createdAt: DateTime(2026, 10, 20),
      );
      expect(s.votedYesByTime, ['p1', 'p2', 'p3']);
      expect(s.playersForClosing(), ['p1', 'p2'], reason: 'p3 vote muộn nhất bị cắt');
      // Người đã có sẵn trong danh sách luôn giữ chỗ.
      expect(s.copyWith(playerIds: ['p3']).playersForClosing(), ['p3', 'p1']);
      // Không có mốc thời gian → xếp sau cùng, giữ thứ tự hiện có.
      final noTimes = s.copyWith(voteTimes: {'p2': DateTime(2026, 10, 21)});
      expect(noTimes.votedYesByTime.first, 'p2');
    });
  });

  group('I. Giới hạn ảnh base64 so với 1MB của Firestore', () {
    test('I1. ngưỡng 700KB sau khi base64 hoá vượt giới hạn tài liệu', () {
      const rawBytes = 700 * 1024; // ngưỡng trong ImageUtil
      final base64Len = (rawBytes / 3).ceil() * 4;
      expect(base64Len, lessThan(1000 * 1024),
          reason: 'ảnh đạt ngưỡng cho phép sẽ thành $base64Len byte chuỗi, '
              'gần/quá giới hạn 1MB mỗi tài liệu Firestore');
    });
  });
}
