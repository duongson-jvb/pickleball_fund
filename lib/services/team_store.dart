import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';

import '../models/models.dart';
import 'team_repository.dart';
import 'zalo_bot_service.dart';
import 'zalo_vote_sync.dart';

/// Giữ toàn bộ dữ liệu realtime của nhóm và các giá trị tính toán
/// (số dư từng người, quỹ chung, người sắp hết tiền...).
class TeamStore extends ChangeNotifier {
  TeamStore(this.repo) {
    _subs = [
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
      }, onError: _onError),
      repo.watchSessions().listen((v) {
        sessions = v;
        _loaded.add('sessions');
        notifyListeners();
        _processInbox();
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
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _pendingInbox = [];
  bool _processingInbox = false;
  bool _inboxDirty = false;
  String? lastZaloInboxSummary;

  /// Biến các tin trong zaloInbox thành vote rồi xoá khỏi hộp thư.
  Future<void> _processInbox() async {
    if (_processingInbox || _pendingInbox.isEmpty) return;
    // Cần đủ dữ liệu (người chơi, buổi chơi) mới khớp được.
    if (!_loaded.contains('players') || !_loaded.contains('sessions') ||
        !_loaded.contains('settings')) {
      return;
    }
    _processingInbox = true;
    try {
      final docs = _pendingInbox;
      final updates = <ZaloUpdate>[];
      final idOf = <String, String>{}; // messageId -> docId
      for (final d in docs) {
        final u = ZaloUpdate.fromInboxDoc(d.id, d.data());
        if (u != null) {
          updates.add(u);
          idOf[u.messageId] = d.id;
        }
      }
      final keep = <String>{};
      if (updates.isNotEmpty) {
        final r = await ZaloVoteSync.apply(this, updates);
        if (r.appliedNames.isNotEmpty) {
          lastZaloInboxSummary = 'Đã nhận vote từ Zalo: ${r.appliedNames.join(', ')}'
              '${r.createdNames.isNotEmpty ? ' · tự thêm: ${r.createdNames.join(', ')}' : ''}';
        }
        // Chưa có buổi nào đang vote: giữ lại tin giống vote tối đa 3 ngày,
        // để khi tạo buổi mới sẽ được tính.
        final cutoff = DateTime.now().subtract(const Duration(days: 3));
        for (final u in updates) {
          if (r.unprocessedIds.contains(u.messageId) && u.date.isAfter(cutoff)) {
            keep.add(idOf[u.messageId]!);
          }
        }
      }
      final toDelete = docs.map((d) => d.id).where((id) => !keep.contains(id)).toList();
      // Giữ lại các tin chưa xử lý để lần sau (khi có buổi vote) tính tiếp.
      _pendingInbox = docs.where((d) => keep.contains(d.id)).toList();
      if (toDelete.isNotEmpty) await repo.deleteZaloInbox(toDelete);
      notifyListeners();
    } catch (_) {
      // Lỗi mạng: tin vẫn còn trong hộp thư, lần sau xử lý lại.
    } finally {
      _processingInbox = false;
      if (_inboxDirty) {
        _inboxDirty = false;
        _processInbox();
      }
    }
  }

  final TeamRepository repo;
  late final List<StreamSubscription> _subs;
  final Set<String> _loaded = {};

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

  String playerName(String id) => playerById(id)?.name ?? '(đã xoá)';

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

  /// Số dư quỹ chung.
  int get commonFund =>
      ledger.where((e) => e.isCommonFund).fold(0, (a, e) => a + e.amount);

  /// Quỹ chung nếu bỏ qua các dòng thuộc một buổi / chi phí (để tính lại).
  int commonFundExcluding(String refId) => ledger
      .where((e) => e.isCommonFund && e.refId != refId)
      .fold(0, (a, e) => a + e.amount);

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

  /// Giá nước mặc định cho một ngày (theo lần sửa gần nhất trước ngày đó).
  Map<String, int> defaultDrinkPrices(DateTime day) => {
        for (final d in drinkTypes.where((d) => d.active))
          d.id: d.priceOn(day),
      };

  @override
  void dispose() {
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
