import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/models.dart';
import 'settlement.dart';

/// Truy cập Firestore cho một nhóm: teams/{teamId}/...
class TeamRepository {
  TeamRepository(this.teamId, {FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final String teamId;
  final FirebaseFirestore _db;

  /// Hàng đợi tính tiền theo từng buổi / chi phí: hai lần lưu cùng lúc cho
  /// cùng một buổi sẽ chạy tuần tự, tránh ghi trùng dòng sổ quỹ.
  final Map<String, Future<void>> _settleChains = {};

  Future<void> _chained(String key, Future<void> Function() job) {
    final prev = _settleChains[key] ?? Future<void>.value();
    final next = prev.catchError((_) {}).then((_) => job());
    _settleChains[key] = next;
    return next.whenComplete(() {
      if (identical(_settleChains[key], next)) _settleChains.remove(key);
    });
  }

  DocumentReference<Map<String, dynamic>> get teamDoc =>
      _db.collection('teams').doc(teamId);
  CollectionReference<Map<String, dynamic>> get players =>
      teamDoc.collection('players');
  CollectionReference<Map<String, dynamic>> get ledger =>
      teamDoc.collection('ledger');
  CollectionReference<Map<String, dynamic>> get drinkTypes =>
      teamDoc.collection('drinkTypes');
  CollectionReference<Map<String, dynamic>> get sessions =>
      teamDoc.collection('sessions');
  CollectionReference<Map<String, dynamic>> get expenses =>
      teamDoc.collection('expenses');
  /// Hộp thư tin Zalo do Cloudflare Worker (webhook) ghi vào.
  CollectionReference<Map<String, dynamic>> get zaloInbox =>
      teamDoc.collection('zaloInbox');

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> watchZaloInbox() =>
      zaloInbox.orderBy('date').limit(200).snapshots().map((s) => s.docs);

  Future<void> deleteZaloInbox(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final batch = _db.batch();
    for (final id in ids) {
      batch.delete(zaloInbox.doc(id));
    }
    await batch.commit();
  }

  // ---------------------------------------------------------------- streams
  Stream<TeamSettings> watchSettings() =>
      teamDoc.snapshots().map(TeamSettings.fromDoc);

  Stream<List<Player>> watchPlayers() => players
      .orderBy('createdAt')
      .snapshots()
      .map((s) => s.docs.map(Player.fromDoc).toList());

  Stream<List<LedgerEntry>> watchLedger() => ledger
      .orderBy('date', descending: true)
      .snapshots()
      .map((s) => s.docs.map(LedgerEntry.fromDoc).toList());

  Stream<List<DrinkType>> watchDrinkTypes() => drinkTypes
      .orderBy('name')
      .snapshots()
      .map((s) => s.docs.map(DrinkType.fromDoc).toList());

  Stream<List<Session>> watchSessions() => sessions
      .orderBy('date', descending: true)
      .snapshots()
      .map((s) => s.docs.map(Session.fromDoc).toList());

  Stream<List<Expense>> watchExpenses() => expenses
      .orderBy('date', descending: true)
      .snapshots()
      .map((s) => s.docs.map(Expense.fromDoc).toList());

  // ------------------------------------------------------------------- team
  Future<void> ensureTeam(String name) async {
    final snap = await teamDoc.get();
    if (!snap.exists) {
      await teamDoc.set({
        'name': name,
        'lowBalanceThreshold': 50000,
        'bankInfo': '',
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> updateSettings(Map<String, dynamic> data) =>
      teamDoc.set(data, SetOptions(merge: true));

  // ---------------------------------------------------------------- players
  Future<void> addPlayer(String name, {String phone = '', String note = ''}) =>
      players.add({
        'name': name.trim(),
        'phone': phone.trim(),
        'note': note.trim(),
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
      });

  Future<void> updatePlayer(String id, Map<String, dynamic> data) =>
      players.doc(id).update(data);

  /// Tự tạo người chơi từ người reply trên Zalo (chưa có trong danh sách).
  /// Trả về id người chơi mới.
  Future<String> addPlayerFromZalo({
    required String zaloId,
    required String zaloName,
  }) async {
    final name = zaloName.trim().isEmpty
        ? 'Zalo ${zaloId.length > 4 ? zaloId.substring(zaloId.length - 4) : zaloId}'
        : zaloName.trim();
    final ref = await players.add({
      'name': name,
      'phone': '',
      'note': 'Tự thêm từ Zalo',
      'active': true,
      'zaloId': zaloId,
      'zaloName': zaloName,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  /// Xoá người chơi và toàn bộ giao dịch của người đó.
  Future<void> deletePlayer(String id) async {
    final batch = _db.batch();
    final entries = await ledger.where('playerId', isEqualTo: id).get();
    for (final d in entries.docs) {
      batch.delete(d.reference);
    }
    batch.delete(players.doc(id));
    await batch.commit();
  }

  // ----------------------------------------------------------------- ledger
  /// Nộp quỹ cho một người.
  Future<void> deposit({
    required String playerId,
    required int amount,
    String note = '',
    DateTime? date,
  }) =>
      ledger.add(LedgerEntry(
        id: '',
        playerId: playerId,
        amount: amount,
        type: LedgerType.deposit,
        note: note,
        date: date ?? DateTime.now(),
        createdAt: DateTime.now(),
      ).toMap());

  /// Nộp quỹ cho tất cả: chia đều theo đầu người.
  Future<void> depositForAll({
    required int amount,
    required List<String> playerIds,
    String note = '',
    DateTime? date,
  }) async {
    final shares = Settlement.splitEqually(amount, playerIds);
    final batch = _db.batch();
    final now = DateTime.now();
    shares.forEach((pid, share) {
      batch.set(
        ledger.doc(),
        LedgerEntry(
          id: '',
          playerId: pid,
          amount: share,
          type: LedgerType.deposit,
          note: note.isEmpty ? 'Nộp chung, chia đều' : note,
          date: date ?? now,
          createdAt: now,
        ).toMap(),
      );
    });
    await batch.commit();
  }

  /// Điều chỉnh thủ công số dư (dương/âm).
  Future<void> adjust({
    required String? playerId,
    required int amount,
    String note = '',
  }) =>
      ledger.add(LedgerEntry(
        id: '',
        playerId: playerId,
        amount: amount,
        type: LedgerType.adjust,
        note: note,
        date: DateTime.now(),
        createdAt: DateTime.now(),
      ).toMap());

  /// Nộp vào quỹ chung.
  Future<void> addCommonFund({
    required int amount,
    String note = '',
    DateTime? date,
  }) =>
      ledger.add(LedgerEntry(
        id: '',
        playerId: null,
        amount: amount,
        type: LedgerType.commonIn,
        note: note,
        date: date ?? DateTime.now(),
        createdAt: DateTime.now(),
      ).toMap());

  Future<void> deleteLedgerEntry(String id) => ledger.doc(id).delete();

  // ------------------------------------------------------------ drink types
  Future<void> addDrinkType(String name, int price) => drinkTypes.add({
        'name': name.trim(),
        'active': true,
        'prices': [
          DrinkPrice(date: DateTime.now(), price: price).toMap(),
        ],
      });

  Future<void> updateDrinkType(DrinkType type,
      {String? name, bool? active}) =>
      drinkTypes.doc(type.id).update({
        'name': ?name?.trim(),
        'active': ?active,
      });

  /// Thêm / sửa giá nước hiệu lực từ một ngày.
  Future<void> setDrinkPrice(DrinkType type, DateTime date, int price) {
    final day = DateTime(date.year, date.month, date.day);
    final list = type.prices
        .where((p) =>
            DateTime(p.date.year, p.date.month, p.date.day) != day)
        .toList()
      ..add(DrinkPrice(date: day, price: price))
      ..sort((a, b) => a.date.compareTo(b.date));
    return drinkTypes
        .doc(type.id)
        .update({'prices': list.map((e) => e.toMap()).toList()});
  }

  Future<void> deleteDrinkType(String id) => drinkTypes.doc(id).delete();

  // --------------------------------------------------------------- sessions
  Future<String> createSession(Session s) async {
    final ref = await sessions.add(s.toMap());
    return ref.id;
  }

  /// Cập nhật một vài trường của buổi chơi mà không tính lại tiền
  /// (dùng cho vote, tin Zalo đang chờ...).
  Future<void> updateSessionFields(String id, Map<String, dynamic> data) =>
      sessions.doc(id).update(data);

  Future<void> deleteSession(String id) async {
    final batch = _db.batch();
    final entries = await ledger.where('refId', isEqualTo: id).get();
    for (final d in entries.docs) {
      batch.delete(d.reference);
    }
    batch.delete(sessions.doc(id));
    await batch.commit();
  }

  /// Lưu buổi chơi và tính lại toàn bộ tiền (sân, nước, quỹ chung).
  ///
  /// Cách làm: xoá các dòng sổ quỹ cũ của buổi này rồi ghi lại dòng mới,
  /// nên có thể gọi lại bao nhiêu lần cũng được (idempotent).
  /// [commonFundExcludingThis] là số dư quỹ chung hiện tại KHÔNG tính các
  /// dòng của buổi này.
  Future<void> saveAndSettleSession(
    Session session, {
    required int commonFundExcludingThis,
  }) =>
      _chained('session:${session.id}', () => _settleSession(session, commonFundExcludingThis));

  Future<void> _settleSession(Session session, int commonFundExcludingThis) async {
    final settlement = Settlement.computeSession(
      session: session,
      commonFundAvailable: commonFundExcludingThis,
    );
    final updated = session.copyWith(settlement: settlement);

    final old = await ledger.where('refId', isEqualTo: session.id).get();
    final batch = _db.batch();
    for (final d in old.docs) {
      batch.delete(d.reference);
    }
    batch.set(sessions.doc(session.id), updated.toMap());

    final now = DateTime.now();
    final label = session.title.isEmpty ? 'Buổi chơi' : session.title;

    if (settlement.commonUsed > 0) {
      batch.set(
        ledger.doc(),
        LedgerEntry(
          id: '',
          playerId: null,
          amount: -settlement.commonUsed,
          type: LedgerType.commonOut,
          refType: 'session',
          refId: session.id,
          note: 'Tiền sân – $label',
          date: session.date,
          createdAt: now,
        ).toMap(),
      );
    }
    settlement.courtPerPlayer.forEach((pid, amt) {
      if (amt <= 0) return;
      batch.set(
        ledger.doc(),
        LedgerEntry(
          id: '',
          playerId: pid,
          amount: -amt,
          type: LedgerType.court,
          refType: 'session',
          refId: session.id,
          note: 'Tiền sân – $label',
          date: session.date,
          createdAt: now,
        ).toMap(),
      );
    });
    settlement.drinkPerPlayer.forEach((pid, amt) {
      if (amt <= 0) return;
      batch.set(
        ledger.doc(),
        LedgerEntry(
          id: '',
          playerId: pid,
          amount: -amt,
          type: LedgerType.drink,
          refType: 'session',
          refId: session.id,
          note: 'Tiền nước – $label',
          date: session.date,
          createdAt: now,
        ).toMap(),
      );
    });
    await batch.commit();
  }

  // --------------------------------------------------------------- expenses
  Future<void> saveAndSettleExpense(
    Expense expense, {
    required List<String> allActivePlayerIds,
    required int commonFundExcludingThis,
  }) {
    final id = expense.id.isEmpty ? expenses.doc().id : expense.id;
    return _chained('expense:$id',
        () => _settleExpense(expense, id, allActivePlayerIds, commonFundExcludingThis));
  }

  Future<void> _settleExpense(
    Expense expense,
    String id,
    List<String> allActivePlayerIds,
    int commonFundExcludingThis,
  ) async {
    final result = Settlement.computeExpense(
      expense: expense,
      allActivePlayerIds: allActivePlayerIds,
      commonFundAvailable: commonFundExcludingThis,
    );
    final updated = Expense(
      id: id,
      title: expense.title,
      amount: expense.amount,
      date: expense.date,
      playerIds: expense.playerIds,
      note: expense.note,
      commonUsed: result.commonUsed,
      perPlayer: result.perPlayer,
      createdAt: expense.createdAt,
    );

    final old = await ledger.where('refId', isEqualTo: id).get();
    final batch = _db.batch();
    for (final d in old.docs) {
      batch.delete(d.reference);
    }
    batch.set(expenses.doc(id), updated.toMap());

    final now = DateTime.now();
    if (result.commonUsed > 0) {
      batch.set(
        ledger.doc(),
        LedgerEntry(
          id: '',
          playerId: null,
          amount: -result.commonUsed,
          type: LedgerType.commonOut,
          refType: 'expense',
          refId: id,
          note: expense.title,
          date: expense.date,
          createdAt: now,
        ).toMap(),
      );
    }
    result.perPlayer.forEach((pid, amt) {
      if (amt <= 0) return;
      batch.set(
        ledger.doc(),
        LedgerEntry(
          id: '',
          playerId: pid,
          amount: -amt,
          type: LedgerType.expense,
          refType: 'expense',
          refId: id,
          note: expense.title,
          date: expense.date,
          createdAt: now,
        ).toMap(),
      );
    });
    await batch.commit();
  }

  Future<void> deleteExpense(String id) async {
    final batch = _db.batch();
    final entries = await ledger.where('refId', isEqualTo: id).get();
    for (final d in entries.docs) {
      batch.delete(d.reference);
    }
    batch.delete(expenses.doc(id));
    await batch.commit();
  }
}
