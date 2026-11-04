import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';

import '../models/models.dart';
import 'auth_service.dart';
import 'settlement.dart';
import 'share_service.dart';
import 'team_repository.dart';
import 'zalo_bot_service.dart';
import 'zalo_vote_sync.dart';

/// Giữ toàn bộ dữ liệu realtime của nhóm và các giá trị tính toán
/// (số dư từng người, quỹ chung, người sắp hết tiền...).
class TeamStore extends ChangeNotifier {
  TeamStore(this.repo, {AuthService? auth}) : auth = auth ?? AuthService.none() {
    _subs = [
      // Đổi trạng thái đăng nhập (mở/khoá quản trị) → vẽ lại giao diện.
      this.auth.changes.listen((_) {
        notifyListeners();
        _processInbox();
      }),
      repo.watchSettings().listen((v) {
        settings = v;
        _loaded.add('settings');
        notifyListeners();
      }, onError: _onError),
      repo.watchPlayers().listen((v) {
        players = v;
        _loaded.add('players');
        notifyListeners();
      }, onError: _onError),
      repo.watchLedger().listen((v) {
        ledger = v;
        _loaded.add('ledger');
        notifyListeners();
      }, onError: _onError),
      repo.watchDrinkTypes().listen((v) {
        drinkTypes = v;
        _loaded.add('drinks');
        notifyListeners();
        _backfillDrinkCodes();
      }, onError: _onError),
      repo.watchSessions().listen((v) {
        sessions = v;
        _loaded.add('sessions');
        notifyListeners();
        _processInbox();
        _autoCloseExpiredVotes();
        _backfillSessionCodes();
      }, onError: _onError),
      repo.watchExpenses().listen((v) {
        expenses = v;
        _loaded.add('expenses');
        notifyListeners();
      }, onError: _onError),
      // Hộp thư Zalo do webhook (Cloudflare Worker) ghi vào: xử lý ngay khi có.
      repo.watchZaloInbox().listen((docs) {
        _pendingInbox = docs;
        if (_processingInbox) {
          _inboxDirty = true; // có tin mới trong lúc đang xử lý → xử lý lại sau
        } else {
          _processInbox();
        }
      }, onError: (_) {}),
    ];
    // Hạn vote trôi qua mà dữ liệu không đổi → kiểm tra định kỳ để tự chốt.
    _deadlineTimer = Timer.periodic(const Duration(minutes: 1), (_) => _autoCloseExpiredVotes());
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _pendingInbox = [];
  bool _processingInbox = false;
  bool _inboxDirty = false;

  // ------------------------------------------------ tự chốt khi hết hạn vote
  final Set<String> _closing = {};
  Timer? _deadlineTimer;

  /// Buổi đang vote mà đã quá hạn → tự chốt danh sách (lấy người vote "đi",
  /// cắt theo giới hạn nếu có). Chỉ máy quản trị mới ghi được.
  Future<void> _autoCloseExpiredVotes() async {
    if (!isAdmin) return;
    // Tin còn trong hộp thư (vote của người mới, vote webhook chưa ghi được)
    // phải vào buổi TRƯỚC khi chốt, nếu không người đó được bot báo "đã nhận"
    // mà không có tên trong danh sách. Hộp thư xử lý xong sẽ gọi lại hàm này;
    // hộp thư kẹt (mất mạng) thì không chờ quá 30 phút sau hạn vote.
    final inboxBusy = _processingInbox || _pendingInbox.isNotEmpty;
    for (final s in sessions) {
      if (s.status != SessionStatus.voting || !s.voteExpired) continue;
      if (inboxBusy &&
          DateTime.now().isBefore(s.effectiveVoteDeadline.add(const Duration(minutes: 30)))) {
        continue;
      }
      if (_closing.contains(s.id)) continue;
      _closing.add(s.id);
      try {
        // Ưu tiên người vote trước khi phải cắt theo giới hạn (Session.asClosed,
        // cùng phép tính với số dự kiến đã hiện trong lúc vote). Chốt trên bản
        // MỚI NHẤT ở máy chủ: chốt từ bản chụp thì người vừa vote "đi" ngay
        // trước lúc chốt không có tên. Máy khác đã chốt rồi thì thôi.
        final closed = await repo.editSessionFresh(
            s.id, (fresh) => fresh.status == SessionStatus.voting ? fresh.asClosed() : null);
        if (closed == null) continue;
        lastZaloInboxSummary = 'Đã tự chốt "${s.title.isEmpty ? 'buổi chơi' : s.title}" khi hết hạn vote';
        notifyListeners();
        // Báo kết quả lên nhóm. Có webhook thì cron của webhook tự báo (và nhắc bỏ
        // ghim); chỉ gửi từ app khi không có webhook, và chỉ khi vote đã gửi qua bot.
        final st = settings;
        if (!st.zaloWebhookMode && st.hasZaloBot && st.zaloGroupId.isNotEmpty &&
            s.zaloVoteMessageId.isNotEmpty) {
          try {
            // Báo theo danh sách đã chốt thật (bản trên máy chủ), không theo bản
            // chụp lúc bắt đầu chốt.
            await ZaloBotService.forTeam(st, repo.teamId)
                .sendMessage(st.zaloGroupId, ShareService.voteResultText(this, closed));
            await repo.markVoteAnnounced(s.id, seats: closed.seatsTaken);
          } catch (_) {
            // Không gửi được thì thôi, danh sách đã chốt.
          }
        }
      } catch (_) {
        // Thử lại ở lần kiểm tra sau.
      } finally {
        _closing.remove(s.id);
      }
    }
  }
  String? lastZaloInboxSummary;

  /// Biến các tin trong zaloInbox thành vote rồi xoá khỏi hộp thư.
  Future<void> _processInbox() async {
    if (_processingInbox || _pendingInbox.isEmpty) return;
    // Cần đủ dữ liệu (người chơi, buổi chơi) mới khớp được.
    if (!_loaded.contains('players') || !_loaded.contains('sessions') ||
        !_loaded.contains('settings')) {
      return;
    }
    // Xử lý hộp thư ghi vào players/sessions/settings → chỉ máy đang ở chế độ
    // quản trị mới làm (rules từ chối người thường). Tin vẫn nằm chờ trong hộp thư.
    if (!isAdmin) return;
    _processingInbox = true;
    try {
      final docs = _pendingInbox;
      final updates = <ZaloUpdate>[];
      for (final d in docs) {
        final u = ZaloUpdate.fromInboxDoc(d.id, d.data());
        if (u != null) updates.add(u);
      }
      if (updates.isNotEmpty) {
        final r = await ZaloVoteSync.apply(this, updates);
        if (r.appliedNames.isNotEmpty) {
          lastZaloInboxSummary = 'Đã nhận vote từ Zalo: ${r.appliedNames.join(', ')}'
              '${r.createdNames.isNotEmpty ? ' · tự thêm: ${r.createdNames.join(', ')}' : ''}';
        }
      }
      // Tin đã xử lý (kể cả tin bị bỏ qua vì chưa có buổi / gửi trước khi tạo buổi) → xoá.
      _pendingInbox = [];
      await repo.deleteZaloInbox(docs.map((d) => d.id));
      notifyListeners();
    } catch (_) {
      // Lỗi mạng: tin vẫn còn trong hộp thư, lần sau xử lý lại.
    } finally {
      _processingInbox = false;
      if (_inboxDirty) {
        _inboxDirty = false;
        _processInbox();
      } else {
        // Buổi hết hạn vote có thể đang chờ hộp thư xử lý xong mới chốt.
        _autoCloseExpiredVotes();
      }
    }
  }

  final TeamRepository repo;
  final AuthService auth;
  late final List<StreamSubscription> _subs;
  final Set<String> _loaded = {};

  /// Đang ở chế độ quản trị (được sửa dữ liệu) hay chỉ xem/vote.
  bool get isAdmin => auth.isAdminOf(settings.adminUid);

  TeamSettings settings = const TeamSettings(id: '', name: 'Team Pickleball');
  List<Player> players = [];
  List<LedgerEntry> ledger = [];
  List<DrinkType> drinkTypes = [];
  List<Session> sessions = [];
  List<Expense> expenses = [];
  Object? error;

  bool get isReady => _loaded.length >= 6;

  void _onError(Object e) {
    error = e;
    notifyListeners();
  }

  // -------------------------------------------------------------- derived
  List<Player> get activePlayers => players.where((p) => p.active).toList();

  Player? playerById(String id) {
    for (final p in players) {
      if (p.id == id) return p;
    }
    return null;
  }

  String playerName(String id) {
    // Người đính kèm: "<hostId>#n" → "Tên host đính kèm n".
    if (Session.isCompanionId(id)) {
      final host = playerById(Session.hostOf(id))?.name ?? '(đã xoá)';
      return '$host đính kèm ${Session.companionIndex(id)}';
    }
    return playerById(id)?.name ?? '(đã xoá)';
  }

  DrinkType? drinkTypeById(String id) {
    for (final d in drinkTypes) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Số dư từng người (tính từ sổ quỹ).
  Map<String, int> get balances {
    final m = <String, int>{for (final p in players) p.id: 0};
    for (final e in ledger) {
      if (e.playerId == null) continue;
      m[e.playerId!] = (m[e.playerId!] ?? 0) + e.amount;
    }
    return m;
  }

  int balanceOf(String playerId) => balances[playerId] ?? 0;

  /// Số dư của một người SAU buổi [s] (xem [Settlement.balanceAfter]).
  int balanceAfter(Session s, String playerId) => s.status == SessionStatus.closed
      ? balanceOf(playerId)
      : Settlement.balanceAfter(
          session: s, playerId: playerId, sessions: sessions, ledger: ledger);

  /// Số dư quỹ chung.
  int get commonFund =>
      ledger.where((e) => e.isCommonFund).fold(0, (a, e) => a + e.amount);

  /// Quỹ chung nếu bỏ qua các dòng thuộc một buổi / chi phí (để tính lại).
  int commonFundExcluding(String refId) => ledger
      .where((e) => e.isCommonFund && e.refId != refId)
      .fold(0, (a, e) => a + e.amount);

  /// Quỹ chung dành cho buổi [s] (xem [Settlement.commonFundFor]).
  int commonFundFor(Session s) =>
      Settlement.commonFundFor(session: s, sessions: sessions, ledger: ledger);

  /// Tiền của một buổi để hiển thị: đã chốt thì đúng số đã trừ vào quỹ, đang
  /// vote thì số dự kiến theo danh sách hiện tại ([Settlement.estimate]).
  SessionSettlement settlementOf(Session s) =>
      Settlement.estimate(session: s, sessions: sessions, ledger: ledger);

  /// Tổng quỹ cá nhân của mọi người.
  int get totalPlayerBalance =>
      balances.values.fold(0, (a, b) => a + b);

  /// Người sắp hết tiền (< ngưỡng cảnh báo).
  List<Player> get lowBalancePlayers {
    final b = balances;
    final list = activePlayers
        .where((p) => (b[p.id] ?? 0) < settings.lowBalanceThreshold)
        .toList()
      ..sort((x, y) => (b[x.id] ?? 0).compareTo(b[y.id] ?? 0));
    return list;
  }

  List<LedgerEntry> ledgerOf(String playerId) =>
      ledger.where((e) => e.playerId == playerId).toList();

  List<LedgerEntry> get commonFundLedger =>
      ledger.where((e) => e.isCommonFund).toList();

  /// Mã ngắn kế tiếp cho loại nước mới (N1, N2...).
  int get nextDrinkCode =>
      drinkTypes.fold<int>(0, (m, d) => d.code > m ? d.code : m) + 1;

  /// Mã ngắn kế tiếp cho buổi mới (xem [Session.nextCode]).
  int get nextSessionCode => Session.nextCode(sessions);

  /// Mã cho buổi được mở lại vote (xem [Session.codeForReopen]).
  int codeForReopen(Session s) => Session.codeForReopen(sessions, s);

  bool _backfillingSessionCodes = false;

  /// Gán mã ngắn cho các buổi còn mở vote mà chưa có mã hoặc trùng mã với
  /// buổi khác (chỉ máy quản trị ghi được; quy tắc ở [Session.codeFixes]).
  /// Thiếu mã thì vote trống vẫn áp cho buổi gần nhất, nhưng không nhắn được
  /// đúng buổi khi nhiều buổi cùng mở.
  Future<void> _backfillSessionCodes() async {
    if (_backfillingSessionCodes || !isAdmin) return;
    final fixes = Session.codeFixes(sessions);
    if (fixes.isEmpty) return;
    _backfillingSessionCodes = true;
    try {
      for (final e in fixes.entries) {
        await repo.updateSessionFields(e.key, {'code': e.value});
      }
    } catch (_) {
      // Lần cập nhật sau sẽ thử lại.
    } finally {
      _backfillingSessionCodes = false;
    }
  }

  bool _backfillingCodes = false;

  /// Gán mã ngắn cho các loại nước cũ chưa có mã (chỉ máy quản trị ghi được).
  Future<void> _backfillDrinkCodes() async {
    if (_backfillingCodes || !isAdmin) return;
    final missing = drinkTypes.where((d) => d.code <= 0).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (missing.isEmpty) return;
    _backfillingCodes = true;
    try {
      var next = nextDrinkCode;
      for (final d in missing) {
        await repo.updateDrinkType(d, code: next++);
      }
    } catch (_) {
      // Lần cập nhật sau sẽ thử lại.
    } finally {
      _backfillingCodes = false;
    }
  }

  /// Giá nước mặc định cho một ngày (theo lần sửa gần nhất trước ngày đó).
  Map<String, int> defaultDrinkPrices(DateTime day) => {
        for (final d in drinkTypes.where((d) => d.active))
          d.id: d.priceOn(day),
      };

  @override
  void dispose() {
    _deadlineTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

/// Cung cấp [TeamStore] cho cây widget.
class TeamScope extends InheritedNotifier<TeamStore> {
  const TeamScope({super.key, required TeamStore store, required super.child})
      : super(notifier: store);

  static TeamStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TeamScope>();
    assert(scope != null, 'TeamScope không có trong cây widget');
    return scope!.notifier!;
  }
}
