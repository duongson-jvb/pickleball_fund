import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/models.dart';
import 'settlement.dart';

/// Truy cập Firestore cho một nhóm: teams/{teamId}/...
class TeamRepository {
  TeamRepository(this.teamId, {FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final String teamId;
  final FirebaseFirestore _db;

  /// Hàng đợi tính tiền: MỌI lần tính tiền (buổi chơi lẫn chi phí) chạy tuần
  /// tự với nhau, không chỉ riêng từng buổi. Lý do: tất cả đều tiêu chung một
  /// số dư quỹ chung, nếu chạy song song thì hai bên cùng thấy số dư cũ và
  /// quỹ chung bị trừ hai lần (có thể âm).
  Future<void> _settleQueue = Future<void>.value();

  Future<void> _chained(Future<void> Function() job) {
    final done = Completer<void>();
    _settleQueue = _settleQueue.then((_) async {
      try {
        await job();
        done.complete();
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
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

  /// Dấu "đã báo kết quả vote" của một buổi (webhook cron cũng ghi vào đây).
  Future<void> markVoteAnnounced(String sessionId, {required int seats}) =>
      teamDoc.collection('zaloVoteState').doc(sessionId).set({
        'announcedAt': FieldValue.serverTimestamp(),
        'seats': seats,
      }, SetOptions(merge: true));

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

  /// Ghi uid tài khoản quản trị vào nhóm (đặt mã bảo mật lần đầu).
  Future<void> claimAdmin(String uid) => teamDoc.set({'adminUid': uid}, SetOptions(merge: true));

  /// Người thường (không phải quản trị) chỉ được đổi vote của buổi đang mở vote.
  Future<void> setVote(String sessionId, String playerId, bool vote, {int companions = 0}) =>
      sessions.doc(sessionId).update({
        'votes.$playerId': vote,
        // Mốc thời gian vote để khi đủ người thì ưu tiên ai vote trước.
        'voteTimes.$playerId': Timestamp.fromDate(DateTime.now()),
        // Người đính kèm đi cùng (chỉ khi vote "đi").
        'companions.$playerId': (vote && companions > 0) ? companions : FieldValue.delete(),
      });

  // -------------------------------------------- số liệu gốc lúc tính tiền
  /// Số dư quỹ chung đọc THẲNG từ Firestore, bỏ qua các dòng của
  /// [excludeRefId] (buổi / chi phí đang được tính lại).
  ///
  /// Phải đọc tại đây thay vì nhận từ màn hình: số dư màn hình giữ có thể đã
  /// cũ, và hai lần lưu gần nhau sẽ cùng tiêu một số dư.
  Future<int> _commonFundExcluding(String? excludeRefId) async {
    final snap = await ledger.where('type', whereIn: [
      LedgerType.commonIn.key,
      LedgerType.commonOut.key,
      LedgerType.adjust.key,
    ]).get();
    var sum = 0;
    for (final d in snap.docs) {
      final data = d.data();
      if (data['playerId'] != null) continue; // chỉ tính dòng của quỹ chung
      if (excludeRefId != null && data['refId'] == excludeRefId) continue;
      final a = data['amount'];
      sum += a is int ? a : (a is num ? a.round() : 0);
    }
    return sum;
  }

  /// Danh sách người chơi đang hoạt động, đọc thẳng từ Firestore.
  Future<List<String>> _activePlayerIds() async {
    final snap = await players.orderBy('createdAt').get();
    return [
      for (final d in snap.docs)
        if (d.data()['active'] != false) d.id,
    ];
  }

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

  /// Xoá người chơi: xoá chính người đó, mọi giao dịch của họ, và gỡ sạch dấu
  /// vết của họ khỏi các buổi chơi / chi phí rồi tính lại tiền những mục đó.
  ///
  /// "Dấu vết" gồm cả nước của NGƯỜI ĐÍNH KÈM đi cùng họ (id ảo `<id>#1`):
  /// tiền nước đó tính vào người vote, bỏ sót thì lần lưu sau lại sinh dòng sổ
  /// quỹ cho người đã xoá.
  ///
  /// Không gỡ khỏi buổi chơi thì lần sau buổi đó được lưu lại (sửa tiền sân,
  /// ghi nước qua Zalo, tự chốt khi hết hạn vote...) sẽ sinh lại dòng sổ quỹ
  /// cho người đã xoá - tiền "ma" cộng vào tổng quỹ mà không màn hình nào hiện.
  ///
  /// Phần tiền sân / chi phí người bị xoá đang gánh sẽ được chia lại cho
  /// những người còn lại trong buổi đó.
  Future<void> deletePlayer(String id) async {
    // 1. Xoá người và giao dịch của họ TRƯỚC, để các bước tính lại bên dưới
    //    không còn coi họ là người chơi đang hoạt động.
    final batch = _db.batch();
    final entries = await ledger.where('playerId', isEqualTo: id).get();
    for (final d in entries.docs) {
      batch.delete(d.reference);
    }
    batch.delete(players.doc(id));
    await batch.commit();

    // 2. Gỡ khỏi các buổi chơi (danh sách chơi, vote, nước) rồi tính lại.
    final sessionDocs = await sessions.get();
    for (final d in sessionDocs.docs) {
      final s = Session.fromDoc(d);
      if (!s.mentions(id)) continue;
      // Xoá người chơi là cố ý bỏ vote của họ → không gộp lại từ máy chủ.
      await saveAndSettleSession(s.withoutPlayer(id), keepRemoteVotes: false);
    }

    // 3. Gỡ khỏi các chi phí có chọn người rồi tính lại.
    final expenseDocs = await expenses.get();
    for (final d in expenseDocs.docs) {
      final e = Expense.fromDoc(d);
      if (!e.playerIds.contains(id) && !e.perPlayer.containsKey(id)) continue;
      final remaining = e.playerIds.where((p) => p != id).toList();
      // Chi phí chỉ chọn mình người bị xoá: để danh sách rỗng sẽ thành "chia
      // cho tất cả", nên xoá hẳn chi phí đó thay vì bắt cả nhóm gánh.
      if (!e.isForEveryone && remaining.isEmpty) {
        await deleteExpense(e.id);
        continue;
      }
      await saveAndSettleExpense(e.copyWith(playerIds: remaining));
    }
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
  Future<void> addDrinkType(String name, int price, {int code = 0}) => drinkTypes.add({
        'name': name.trim(),
        'active': true,
        'code': code,
        'prices': [
          DrinkPrice(date: DateTime.now(), price: price).toMap(),
        ],
      });

  Future<void> updateDrinkType(DrinkType type,
      {String? name, bool? active, int? code}) =>
      drinkTypes.doc(type.id).update({
        'name': ?name?.trim(),
        'active': ?active,
        'code': ?code,
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
  /// Số dư quỹ chung được đọc lại từ Firestore ngay lúc tính, màn hình không
  /// cần (và không được) truyền vào.
  /// [keepRemoteVotes] = false khi người gọi CỐ Ý bỏ vote (xoá người chơi).
  /// Mặc định true: giữ lại vote mà webhook vừa ghi trong lúc màn hình đang
  /// cầm bản chụp cũ.
  Future<void> saveAndSettleSession(Session session,
          {bool keepRemoteVotes = true}) =>
      _chained(() => _settleSession(session, keepRemoteVotes));

  Future<void> _settleSession(Session raw, bool keepRemoteVotes) async {
    // Vote do webhook ghi thẳng vào Firestore có thể tới SAU lúc màn hình chụp
    // bản này. Ghi đè cả tài liệu sẽ làm mất chúng, nên gộp lại trước khi ghi.
    var merged = raw;
    if (keepRemoteVotes) {
      final current = await sessions.doc(raw.id).get();
      if (current.exists) merged = raw.mergeNewerVotes(Session.fromDoc(current));
    }
    // Dọn nước của người đính kèm đã bị bỏ trước khi tính: nếu không, người
    // vote vẫn bị trừ tiền nước của một người không còn đi buổi này.
    final session = merged.pruneCompanionDrinks();
    final settlement = Settlement.computeSession(
      session: session,
      commonFundAvailable: await _commonFundExcluding(session.id),
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
  /// Lưu chi phí và tính lại tiền. Danh sách người chơi đang hoạt động và số
  /// dư quỹ chung đều được đọc lại từ Firestore ngay lúc tính.
  Future<void> saveAndSettleExpense(Expense expense) {
    final id = expense.id.isEmpty ? expenses.doc().id : expense.id;
    return _chained(() => _settleExpense(expense, id));
  }

  Future<void> _settleExpense(Expense expense, String id) async {
    final result = Settlement.computeExpense(
      expense: expense,
      allActivePlayerIds: await _activePlayerIds(),
      commonFundAvailable: await _commonFundExcluding(id),
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
