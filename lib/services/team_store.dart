import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/models.dart';
import 'team_repository.dart';

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
      }, onError: _onError),
      repo.watchExpenses().listen((v) {
        expenses = v;
        _loaded.add('expenses');
        notifyListeners();
      }, onError: _onError),
    ];
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
