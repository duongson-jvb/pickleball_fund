import '../models/models.dart';

/// Các hàm thuần túy tính toán chia tiền. Không phụ thuộc Firestore để dễ test.
class Settlement {
  Settlement._();

  /// Chia đều [total] cho [ids]. Phần dư (do chia không hết) dồn cho những
  /// người đầu danh sách, đảm bảo tổng các phần = [total].
  static Map<String, int> splitEqually(int total, List<String> ids) {
    if (ids.isEmpty || total <= 0) return {};
    final base = total ~/ ids.length;
    var remainder = total - base * ids.length;
    final result = <String, int>{};
    for (final id in ids) {
      var share = base;
      if (remainder > 0) {
        share += 1;
        remainder -= 1;
      }
      // Một id xuất hiện nhiều lần (người vote kèm người đính kèm) thì cộng dồn:
      // phần của người đính kèm trừ vào người vote.
      result[id] = (result[id] ?? 0) + share;
    }
    return result;
  }

  /// Tính tiền cho một buổi chơi.
  ///
  /// - Tiền sân chia theo đầu người (người chơi + khách).
  /// - Phần của khách thu tiền mặt, không trừ quỹ.
  /// - Phần của người chơi: ưu tiên trừ quỹ chung ([commonFundAvailable]),
  ///   phần thiếu chia đều cho người chơi trong buổi.
  /// - Tiền nước: mỗi người tự trả theo số lượng x giá nước của buổi.
  static SessionSettlement computeSession({
    required Session session,
    required int commonFundAvailable,
  }) {
    final players = session.playerIds;
    // Mỗi người vote kèm N người đính kèm = N+1 suất; suất của người đính kèm
    // tính vào người vote.
    final units = <String>[
      for (final id in players)
        for (var i = 0; i <= session.companionsOf(id); i++) id,
    ];
    final participants = units.length + session.guestCount;

    var perHead = 0;
    var guestCash = 0;
    var commonUsed = 0;
    var courtPerPlayer = <String, int>{};

    if (participants > 0 && session.courtFee > 0) {
      perHead = (session.courtFee / participants).ceil();
      guestCash = perHead * session.guestCount;
      if (guestCash > session.courtFee) guestCash = session.courtFee;
      final teamShare = session.courtFee - guestCash;
      if (units.isNotEmpty) {
        commonUsed = commonFundAvailable.clamp(0, teamShare);
        final remaining = teamShare - commonUsed;
        courtPerPlayer = splitEqually(remaining, units);
      } else {
        // Chỉ có khách: toàn bộ tiền sân thu tiền mặt.
        guestCash = session.courtFee;
      }
    }

    // Tiền nước: nước của người đính kèm ("<id>#1") gộp vào người vote.
    final drinkPerPlayer = <String, int>{};
    session.drinks.forEach((pid, items) {
      var sum = 0;
      items.forEach((drinkId, qty) {
        sum += qty * (session.drinkPrices[drinkId] ?? 0);
      });
      if (sum <= 0) return;
      final owner = Session.isCompanionId(pid) ? Session.hostOf(pid) : pid;
      drinkPerPlayer[owner] = (drinkPerPlayer[owner] ?? 0) + sum;
    });

    return SessionSettlement(
      participants: participants,
      perHead: perHead,
      guestCash: guestCash,
      commonUsed: commonUsed,
      courtPerPlayer: courtPerPlayer,
      drinkPerPlayer: drinkPerPlayer,
    );
  }

  /// Tính chia chi phí khác.
  ///
  /// - Nếu [expense.playerIds] rỗng: chia cho [allActivePlayerIds], ưu tiên
  ///   dùng quỹ chung trước.
  /// - Nếu có chọn người: chia đều cho những người đó, không dùng quỹ chung.
  static ({int commonUsed, Map<String, int> perPlayer}) computeExpense({
    required Expense expense,
    required List<String> allActivePlayerIds,
    required int commonFundAvailable,
  }) {
    if (expense.amount <= 0) return (commonUsed: 0, perPlayer: {});
    if (expense.isForEveryone) {
      final commonUsed = commonFundAvailable.clamp(0, expense.amount);
      final remaining = expense.amount - commonUsed;
      return (
        commonUsed: commonUsed,
        perPlayer: splitEqually(remaining, allActivePlayerIds),
      );
    }
    return (
      commonUsed: 0,
      perPlayer: splitEqually(expense.amount, expense.playerIds),
    );
  }
}
