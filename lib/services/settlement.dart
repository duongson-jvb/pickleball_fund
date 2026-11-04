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
    // Một danh sách duy nhất: ai đang giữ chỗ thì tính tiền cho người đó
    // (đã chốt: danh sách chơi; đang vote: số dự kiến theo danh sách hiện tại,
    // chỉ trừ vào quỹ khi chốt - xem TeamRepository.saveAndSettleSession).
    final players = session.seatHolders;
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

  /// Tiền của một buổi để hiển thị.
  ///
  /// Đã chốt: đúng số đã trừ vào quỹ (lưu trong buổi). Đang vote: số dự kiến,
  /// xem [estimateOpen].
  static SessionSettlement estimate({
    required Session session,
    required List<Session> sessions,
    required List<LedgerEntry> ledger,
  }) {
    if (session.status == SessionStatus.closed) return session.settlement;
    return estimateOpen(sessions: sessions, ledger: ledger, current: session)[session.id]!;
  }

  /// Số dự kiến của các buổi đang mở vote, theo thứ tự buổi diễn ra trước.
  ///
  /// Mỗi buổi tính như thể chốt ngay bây giờ ([Session.asClosed]) nên đúng
  /// bằng số sẽ trừ khi chốt: vote qua Zalo về liên tục mà không ai lưu lại
  /// buổi, nên số đã lưu trong buổi luôn cũ.
  ///
  /// Các buổi dùng chung một quỹ chung: buổi diễn ra trước dùng trước (cũng là
  /// buổi chốt trước), nếu không mỗi buổi đều tưởng được dùng cả quỹ và số dự
  /// kiến cộng lại vượt số quỹ đang có. Dòng sổ quỹ của buổi đang mở (nếu có,
  /// ví dụ bản app cũ còn ghi lúc đang vote) được bỏ ra để không tính hai lần.
  ///
  /// [current] là bản màn hình đang cầm (có thể vừa sửa, chưa về từ máy chủ):
  /// dùng nó thay cho bản cùng id trong [sessions], hoặc thêm vào nếu chưa có.
  static Map<String, SessionSettlement> estimateOpen({
    required List<Session> sessions,
    required List<LedgerEntry> ledger,
    Session? current,
  }) {
    final open = [
      for (final x in sessions)
        if (x.status != SessionStatus.closed && x.id != current?.id) x,
      if (current != null && current.status != SessionStatus.closed) current,
    ]..sort((a, b) {
        final c = a.date.compareTo(b.date);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final openIds = {for (final x in open) x.id};
    var fund = ledger
        .where((e) => e.isCommonFund && !openIds.contains(e.refId))
        .fold(0, (a, e) => a + e.amount);
    final out = <String, SessionSettlement>{};
    for (final x in open) {
      final st = computeSession(
          session: x.asClosed().pruneCompanionDrinks(), commonFundAvailable: fund);
      out[x.id] = st;
      fund -= st.commonUsed;
    }
    return out;
  }

  /// Quỹ chung dành cho buổi [session]: đã chốt thì như lúc tính tiền (bỏ
  /// dòng của chính buổi đó); đang vote thì phần còn lại sau các buổi đang mở
  /// diễn ra trước nó (cùng thứ tự với [estimateOpen]).
  static int commonFundFor({
    required Session session,
    required List<Session> sessions,
    required List<LedgerEntry> ledger,
  }) {
    if (session.status == SessionStatus.closed) {
      return ledger
          .where((e) => e.isCommonFund && e.refId != session.id)
          .fold(0, (a, e) => a + e.amount);
    }
    final est = estimateOpen(sessions: sessions, ledger: ledger, current: session);
    var fund = ledger
        .where((e) => e.isCommonFund && !est.containsKey(e.refId))
        .fold(0, (a, e) => a + e.amount);
    for (final e in est.entries) {
      if (e.key == session.id) break;
      fund -= e.value.commonUsed;
    }
    return fund;
  }

  /// Số dư dự kiến của một người SAU buổi đang vote [session]: trừ trước số
  /// dự kiến (chưa ghi vào sổ quỹ) của buổi này VÀ các buổi đang mở diễn ra
  /// trước nó - người đi cả hai buổi sẽ bị trừ cả hai. Dòng sổ quỹ của buổi
  /// đang mở (nếu có, ví dụ bản app cũ còn ghi lúc đang vote) được bỏ ra trước.
  static int balanceAfter({
    required Session session,
    required String playerId,
    required List<Session> sessions,
    required List<LedgerEntry> ledger,
  }) {
    if (session.status == SessionStatus.closed) {
      // Đã chốt: tiền buổi này đã nằm trong sổ quỹ, số dư hiện tại là đúng.
      return ledger.where((e) => e.playerId == playerId).fold(0, (a, e) => a + e.amount);
    }
    final est = estimateOpen(sessions: sessions, ledger: ledger, current: session);
    var bal = ledger
        .where((e) => e.playerId == playerId && !est.containsKey(e.refId))
        .fold(0, (a, e) => a + e.amount);
    for (final e in est.entries) {
      bal -= (e.value.courtPerPlayer[playerId] ?? 0) + (e.value.drinkPerPlayer[playerId] ?? 0);
      if (e.key == session.id) break;
    }
    return bal;
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
