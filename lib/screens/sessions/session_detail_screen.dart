import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/share_service.dart';
import '../../services/team_store.dart';
import '../../services/zalo_bot_service.dart';
import '../../services/zalo_vote_sync.dart';
import '../../utils/format.dart';
import '../../widgets/admin_gate.dart';
import '../../widgets/common.dart';
import '../share/share_screen.dart';
import 'session_form_screen.dart';

/// Hàm biến đổi buổi chơi: nhận bản MỚI NHẤT, trả về bản đã sửa.
/// Dùng updater thay vì truyền thẳng Session để các thao tác liên tiếp
/// (bấm +1 nước nhiều lần, vote về từ Zalo cùng lúc...) không ghi đè nhau.
typedef SessionUpdater = Session Function(Session latest);
typedef MutateFn = Future<void> Function(SessionUpdater update);

/// Chi tiết buổi chơi: Vote → Người chơi & tiền sân → Nước → Tổng kết.
class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  bool _busy = false;

  // Hàng đợi lưu: mỗi thao tác chạy tuần tự, dựa trên kết quả thao tác trước.
  Future<void> _queue = Future.value();
  Session? _optimistic;
  int _pendingOps = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Session? _session(TeamStore store) =>
      store.sessions.where((s) => s.id == widget.sessionId).firstOrNull;

  /// Áp dụng [update] lên bản mới nhất rồi lưu + tính lại tiền (cần quản trị).
  Future<void> _mutate(SessionUpdater update) async {
    if (!await requireAdmin(context)) return;
    return _enqueue(update);
  }

  Future<void> _enqueue(SessionUpdater update) {
    _pendingOps++;
    if (mounted) setState(() => _busy = true);
    final done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        if (!mounted) return;
        final store = TeamScope.of(context);
        final base = _optimistic ?? _session(store);
        if (base == null) return;
        final next = update(base);
        _optimistic = next;
        await store.repo.saveAndSettleSession(next);
      } catch (e) {
        if (mounted) showSnack(context, 'Lỗi lưu: $e');
      } finally {
        _pendingOps--;
        if (_pendingOps == 0) {
          _optimistic = null;
          if (mounted) setState(() => _busy = false);
        }
        done.complete();
      }
    });
    return done.future;
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final s = _session(store);
    if (s == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyHint('Buổi chơi đã bị xoá'));
    }
    final voting = s.status == SessionStatus.voting;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.title.isEmpty ? fmtWeekday(s.date) : s.title),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: 'Vote (${s.votedYes.length})'),
            Tab(text: 'Người chơi (${s.playerIds.length})'),
            const Tab(text: 'Nước'),
            const Tab(text: 'Tổng kết'),
          ],
        ),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          IconButton(
            tooltip: 'Chia sẻ',
            icon: const Icon(Icons.share),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => ShareScreen(session: s))),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'edit') {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => SessionFormScreen(session: s)));
              } else if (v == 'reopen') {
                await _mutate((l) => l.copyWith(status: SessionStatus.voting));
              } else if (v == 'delete') {
                if (await confirm(context, 'Xoá buổi chơi này?',
                    message: 'Tiền sân, tiền nước đã trừ sẽ được hoàn lại.')) {
                  await store.repo.deleteSession(s.id);
                  if (context.mounted) Navigator.pop(context);
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Sửa thông tin / tiền sân / ảnh')),
              if (!voting) const PopupMenuItem(value: 'reopen', child: Text('Mở lại vote')),
              const PopupMenuItem(value: 'delete', child: Text('Xoá buổi chơi')),
            ],
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _VoteTab(session: s, onMutate: _mutate, onClosed: () => _tabs.animateTo(1)),
          _PlayersTab(session: s, onMutate: _mutate),
          _DrinksTab(session: s, onMutate: _mutate),
          _SummaryTab(session: s),
        ],
      ),
    );
  }
}

// ============================================================== VOTE TAB
class _VoteTab extends StatefulWidget {
  const _VoteTab({required this.session, required this.onMutate, required this.onClosed});
  final Session session;
  final MutateFn onMutate;
  final VoidCallback onClosed;

  @override
  State<_VoteTab> createState() => _VoteTabState();
}

class _VoteTabState extends State<_VoteTab> {
  Session get session => widget.session;
  MutateFn get onMutate => widget.onMutate;

  bool _polling = false;
  bool _disposed = false;
  bool _botBusy = false;
  String? _botStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPolling());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  ZaloBotService _bot(TeamStore store) => ZaloBotService.forTeam(store.settings, store.repo.teamId);

  /// Vòng lặp hỏi Zalo liên tục (long polling) khi đang ở tab Vote.
  Future<void> _startPolling() async {
    if (_polling || _disposed || !mounted) return;
    final store = TeamScope.of(context);
    if (!store.settings.hasZaloBot || session.status != SessionStatus.voting) return;
    if (store.settings.zaloWebhookMode) {
      // Webhook đang bật: Zalo đẩy tin về Firestore, TeamStore tự xử lý.
      setState(() => _botStatus = 'Webhook đang bật: vote từ Zalo tự về, không cần giữ màn hình này.');
      return;
    }
    _polling = true;
    setState(() => _botStatus = 'Đang chờ vote từ Zalo...');
    while (!_disposed) {
      try {
        if (!mounted) break;
        final st = TeamScope.of(context);
        final s = st.settings;
        final current = st.sessions.where((x) => x.id == session.id).firstOrNull;
        if (!s.hasZaloBot || s.zaloWebhookMode || current == null ||
            current.status != SessionStatus.voting) {
          break;
        }
        final updates = await _bot(st).getUpdates(timeoutSeconds: 15);
        if (_disposed) break;
        if (updates.isNotEmpty) await _applyUpdates(updates);
      } catch (e) {
        if (_disposed || !mounted) break;
        setState(() => _botStatus = 'Lỗi kết nối bot: $e');
        await Future.delayed(const Duration(seconds: 10));
      }
    }
    _polling = false;
  }

  Future<void> _applyUpdates(List<ZaloUpdate> updates) async {
    if (!mounted) return;
    final store = TeamScope.of(context);
    final current = store.sessions.where((x) => x.id == session.id).firstOrNull ?? session;
    final r = await ZaloVoteSync.apply(store, updates, target: current);
    if (!mounted) return;
    final parts = <String>[];
    if (r.appliedNames.isNotEmpty) parts.add('Đã nhận vote: ${r.appliedNames.join(', ')}');
    if (r.createdNames.isNotEmpty) parts.add('Tự thêm người chơi: ${r.createdNames.join(', ')}');
    if (r.fullNames.isNotEmpty) parts.add('Đủ người, không nhận: ${r.fullNames.join(', ')}');
    if (r.drinkNotes.isNotEmpty) parts.add('Nước: ${r.drinkNotes.join('; ')}');
    if (r.lateCount > 0) parts.add('${r.lateCount} tin sau hạn vote bị bỏ qua');
    if (r.pendingCount > 0) parts.add('${r.pendingCount} tin chưa khớp tên');
    if (parts.isNotEmpty) {
      setState(() => _botStatus = '${parts.join(' · ')} (${TimeOfDay.now().format(context)})');
      showSnack(context, parts.join(' · '));
    }
  }

  Future<void> _syncNow() async {
    final store = TeamScope.of(context);
    if (store.settings.zaloWebhookMode) {
      showSnack(context,
          'Webhook đang bật: vote tự về qua Firestore. ${store.lastZaloInboxSummary ?? 'Chưa có tin mới.'}');
      return;
    }
    setState(() => _botBusy = true);
    try {
      final updates = await _bot(store).getUpdates(timeoutSeconds: 3);
      if (updates.isEmpty) {
        if (mounted) showSnack(context, 'Không có tin mới từ Zalo');
      } else {
        await _applyUpdates(updates);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Lỗi: $e');
    } finally {
      if (mounted) setState(() => _botBusy = false);
    }
  }

  Future<void> _sendViaBot({required bool asVote}) async {
    final store = TeamScope.of(context);
    final s = store.settings;
    if (s.zaloGroupId.isEmpty) {
      showSnack(context, 'Chưa chọn nhóm Zalo. Vào Cài đặt → Zalo Bot.');
      return;
    }
    setState(() => _botBusy = true);
    try {
      var text = ShareService.voteText(store, session);
      if (asVote) text += '\n👉 REPLY tin này: 1 = đi, 0 = không đi (bot sẽ tự ghi nhận).';
      final id = await _bot(store).sendMessage(s.zaloGroupId, text);
      if (asVote) {
        await store.repo.updateSessionFields(session.id, {'zaloVoteMessageId': id});
      }
      if (mounted) {
        showSnack(context, asVote ? 'Đã gửi vote lên nhóm Zalo' : 'Đã gửi danh sách lên nhóm Zalo');
      }
      if (asVote) _startPolling();
    } catch (e) {
      if (mounted) showSnack(context, 'Lỗi gửi: $e');
    } finally {
      if (mounted) setState(() => _botBusy = false);
    }
  }

  Future<void> _assignPending(ZaloPendingVote p) async {
    final store = TeamScope.of(context);
    final player = await showDialog<Player>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('"${p.name}" là ai?'),
        children: [
          for (final pl in store.activePlayers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, pl),
              child: Text(pl.name),
            ),
        ],
      ),
    );
    if (player == null || !mounted) return;
    bool? vote = p.vote;
    if (vote == null) {
      vote = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${player.name} nhắn "${p.text}"'),
          content: const Text('Tính là đi hay không đi?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Không đi')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Đi')),
          ],
        ),
      );
      if (vote == null) return;
    }
    if (!mounted) return;
    final latest = TeamScope.of(context).sessions.where((x) => x.id == session.id).firstOrNull;
    await ZaloVoteSync.resolvePending(store, latest ?? session, p, player, voteOverride: vote);
  }

  Future<void> _importFromZalo(BuildContext context) async {
    final store = TeamScope.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nhập kết quả vote từ Zalo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Vào Zalo → mở bình chọn → sao chép danh sách người đã vote '
              '(hoặc chụp tên) rồi dán vào đây. App sẽ tự khớp tên với người chơi.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              maxLines: 8,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Dán danh sách tên vào đây...'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Khớp tên')),
        ],
      ),
    );
    if (ok != true) return;
    final matched = ShareService.parseZaloVote(store, ctrl.text);
    if (matched.isEmpty) {
      if (context.mounted) showSnack(context, 'Không khớp được tên nào');
      return;
    }
    await onMutate((l) {
      final votes = {...l.votes};
      for (final id in matched) {
        votes[id] = true;
      }
      return l.copyWith(votes: votes);
    });
    if (context.mounted) {
      showSnack(context, 'Đã đánh dấu ${matched.length} người: '
          '${matched.map(store.playerName).join(', ')}');
    }
  }

  Future<void> _closeVote(BuildContext context) async {
    final yes = session.votedYes;
    final ok = await confirm(
      context,
      'Chốt danh sách ${yes.length} người?',
      message: 'Danh sách người chơi sẽ lấy từ vote. Bạn vẫn có thể thêm/bớt '
          'người sau khi chốt, tiền sẽ được tính lại.',
      okLabel: 'Chốt',
      danger: false,
    );
    if (!ok) return;
    await onMutate((l) => l.copyWith(
          status: SessionStatus.closed,
          // Người vote trước được ưu tiên khi phải cắt theo giới hạn.
          playerIds: l.playersForClosing(),
        ));
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final s = session;
    final voting = s.status == SessionStatus.voting;
    final players = store.activePlayers;
    final hasBot = store.settings.hasZaloBot;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(voting ? (s.voteExpired ? Icons.timer_off_outlined : Icons.how_to_vote) : Icons.lock,
                        size: 20),
                    const SizedBox(width: 8),
                    Text(
                        !voting
                            ? 'Đã chốt danh sách'
                            : s.voteExpired
                                ? 'Hết hạn vote (sẽ tự chốt)'
                                : 'Đang vote',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('${s.votedYes.length}${s.maxPlayers != null ? '/${s.maxPlayers}' : ''} đi'
                        '${s.isFull ? ' · đủ người' : ''}'),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (s.createdByName.isNotEmpty) 'Người tạo: ${s.createdByName}',
                    'Hạn vote: ${fmtDateTime(s.effectiveVoteDeadline)}',
                    s.maxPlayers == null ? 'Không giới hạn số người' : 'Giới hạn ${s.maxPlayers} người',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => ShareService.shareText(
                          context, ShareService.voteText(store, s)),
                      icon: const Icon(Icons.campaign),
                      label: const Text('Tạo vote lên Zalo'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _importFromZalo(context),
                      icon: const Icon(Icons.download),
                      label: const Text('Dán kết quả từ Zalo'),
                    ),
                    if (voting)
                      FilledButton.icon(
                        onPressed: s.votedYes.isEmpty ? null : () => _closeVote(context),
                        icon: const Icon(Icons.check_circle),
                        label: const Text('Chốt danh sách'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (hasBot)
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.smart_toy_outlined, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Zalo Bot: ${store.settings.zaloBotName}',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      if (_botBusy)
                        const SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                  if (_botStatus != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(_botStatus!, style: const TextStyle(fontSize: 12)),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (voting)
                        FilledButton.icon(
                          onPressed: _botBusy ? null : () => _sendViaBot(asVote: true),
                          icon: const Icon(Icons.send),
                          label: Text(s.zaloVoteMessageId.isEmpty
                              ? 'Gửi vote qua bot'
                              : 'Gửi lại vote qua bot'),
                        ),
                      if (!voting)
                        FilledButton.tonalIcon(
                          onPressed: _botBusy ? null : () => _sendViaBot(asVote: false),
                          icon: const Icon(Icons.send),
                          label: const Text('Gửi danh sách qua bot'),
                        ),
                      OutlinedButton.icon(
                        onPressed: _botBusy ? null : _syncNow,
                        icon: const Icon(Icons.sync),
                        label: const Text('Đồng bộ ngay'),
                      ),
                    ],
                  ),
                  if (s.zaloPending.isNotEmpty) ...[
                    const Divider(),
                    const Text('Tin chưa khớp được tên (bấm Gán để chọn người):',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    for (final p in s.zaloPending)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          p.vote == null
                              ? Icons.help_outline
                              : (p.vote! ? Icons.thumb_up_alt_outlined : Icons.thumb_down_alt_outlined),
                          size: 20,
                        ),
                        title: Text(p.name.isEmpty ? '(không tên)' : p.name),
                        subtitle: Text('"${p.text}"', maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                                onPressed: () => _assignPending(p), child: const Text('Gán')),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => ZaloVoteSync.dismissPending(store, s, p),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Bấm vào tên để đánh dấu đi / không đi',
              style: TextStyle(fontSize: 12)),
        ),
        for (final p in players)
          CheckboxListTile(
            value: s.votes[p.id] ?? false,
            title: Text(p.name),
            subtitle: s.votes.containsKey(p.id)
                ? Text(s.votes[p.id]! ? 'Đi' : 'Không đi')
                : const Text('Chưa vote'),
            secondary: CircleAvatar(
                radius: 16, child: Text(p.name.isEmpty ? '?' : p.name[0].toUpperCase())),
            // Vote không cần mã bảo mật: người thường ghi thẳng trường votes
            // (rules chỉ cho đổi votes của buổi đang mở vote).
            onChanged: !voting
                ? null
                : (v) async {
                    final vote = v ?? false;
                    if (store.isAdmin) {
                      await onMutate((l) => l.copyWith(
                            votes: {...l.votes, p.id: vote},
                            voteTimes: {...l.voteTimes, p.id: DateTime.now()},
                          ));
                      return;
                    }
                    // Người thường: tôn trọng hạn vote và giới hạn số người.
                    if (s.voteExpired) {
                      showSnack(context, 'Đã hết hạn vote (${fmtDateTime(s.effectiveVoteDeadline)})');
                      return;
                    }
                    if (vote && s.isFull && s.votes[p.id] != true) {
                      showSnack(context, 'Đã đủ ${s.maxPlayers} người, không nhận thêm');
                      return;
                    }
                    try {
                      await store.repo.setVote(s.id, p.id, vote);
                    } catch (e) {
                      if (context.mounted) showSnack(context, 'Không vote được: $e');
                    }
                  },
          ),
      ],
    );
  }
}

// =========================================================== PLAYERS TAB
class _PlayersTab extends StatelessWidget {
  const _PlayersTab({required this.session, required this.onMutate});
  final Session session;
  final MutateFn onMutate;

  Future<void> _editGuests(BuildContext context) async {
    final ctrl = TextEditingController(text: session.guestCount.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Số khách (không có trong danh sách)'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Số khách',
            helperText: 'Khách chia tiền sân như người chơi nhưng trả tiền mặt, không trừ quỹ.',
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
        ],
      ),
    );
    if (ok == true) {
      final n = (int.tryParse(ctrl.text.trim()) ?? 0).clamp(0, 999);
      await onMutate((l) => l.copyWith(guestCount: n));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final s = session;
    final st = s.settlement;
    final players = store.activePlayers;
    final inList = s.playerIds.toSet();
    final commonAvail = store.commonFundExcluding(s.id);
    final maxShare = st.courtPerPlayer.values.fold(0, (a, b) => a > b ? a : b);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.sports_tennis, size: 20),
                    const SizedBox(width: 8),
                    Text('Tiền sân: ${s.courtFee == 0 ? 'chưa nhập' : vnd(s.courtFee)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => SessionFormScreen(session: s))),
                      child: const Text('Nhập / sửa'),
                    ),
                  ],
                ),
                if (s.courtFee > 0) ...[
                  Text('• ${st.participants} người (${s.playerIds.length} người chơi'
                      '${s.guestCount > 0 ? ' + ${s.guestCount} khách' : ''}) '
                      '→ ${vnd(st.perHead)}/người'),
                  Text('• Quỹ chung trả: ${vnd(st.commonUsed)} '
                      '(quỹ chung có ${vnd(commonAvail)})'),
                  if (st.guestCash > 0) Text('• Khách trả tiền mặt: ${vnd(st.guestCash)}'),
                  Text('• Mỗi người chơi bị trừ: ${vnd(maxShare)}'),
                ],
                if (s.courtImageBase64 != null) ...[
                  const SizedBox(height: 8),
                  Base64Image(s.courtImageBase64!, height: 160),
                ],
              ],
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.person_add_alt),
          title: const Text('Khách (ngoài danh sách)'),
          subtitle: Text('${s.guestCount} người · chia tiền sân, trả tiền mặt'),
          trailing: const Icon(Icons.edit),
          onTap: () => _editGuests(context),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text('Người chơi thực tế (tick để thêm/bớt, tiền tự tính lại)',
                    style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: () => onMutate((l) => l.copyWith(playerIds: l.votedYes)),
                child: const Text('Lấy theo vote'),
              ),
            ],
          ),
        ),
        for (final p in players)
          CheckboxListTile(
            value: inList.contains(p.id),
            title: Text(p.name),
            subtitle: Text(
              [
                'Số dư ${vnd(store.balanceOf(p.id))}',
                if ((st.courtPerPlayer[p.id] ?? 0) > 0) 'sân -${vnd(st.courtPerPlayer[p.id]!)}',
                if ((st.drinkPerPlayer[p.id] ?? 0) > 0) 'nước -${vnd(st.drinkPerPlayer[p.id]!)}',
              ].join(' · '),
            ),
            secondary: s.votes[p.id] == true
                ? const Tooltip(message: 'Đã vote đi', child: Icon(Icons.how_to_vote, color: Colors.teal))
                : const Icon(Icons.person_outline),
            onChanged: (v) => onMutate((l) {
              final ids = [...l.playerIds];
              if (v == true) {
                if (!ids.contains(p.id)) ids.add(p.id);
              } else {
                ids.remove(p.id);
              }
              return l.copyWith(playerIds: ids);
            }),
          ),
      ],
    );
  }
}

// ============================================================ DRINKS TAB
class _DrinksTab extends StatelessWidget {
  const _DrinksTab({required this.session, required this.onMutate});
  final Session session;
  final MutateFn onMutate;

  Future<void> _editPrice(BuildContext context, DrinkType t, int current) async {
    final store = TeamScope.of(context);
    final ctrl = TextEditingController(text: current.toString());
    var applyGlobally = true;
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Giá ${t.name} buổi này'),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AmountField(controller: ctrl, label: 'Giá', autofocus: true),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: applyGlobally,
                  onChanged: (v) => setState(() => applyGlobally = v ?? true),
                  title: const Text('Lưu làm giá mặc định từ ngày này'),
                  subtitle: const Text('Các buổi sau sẽ dùng giá này nếu không sửa'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) Navigator.pop(ctx, true);
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final price = parseAmount(ctrl.text);
    if (applyGlobally) await store.repo.setDrinkPrice(t, session.date, price);
    await onMutate((l) => l.copyWith(drinkPrices: {...l.drinkPrices, t.id: price}));
  }

  /// Cộng/trừ số lượng nước, đồng thời "đóng băng" giá của loại nước vào buổi
  /// nếu chưa có (để sau này đổi giá mặc định không ảnh hưởng buổi đã tính).
  Future<void> _changeQty(String pid, DrinkType t, int delta, int fallbackPrice) =>
      onMutate((l) {
        final drinks = {for (final e in l.drinks.entries) e.key: {...e.value}};
        final m = drinks.putIfAbsent(pid, () => {});
        final qty = (m[t.id] ?? 0) + delta;
        if (qty <= 0) {
          m.remove(t.id);
        } else {
          m[t.id] = qty;
        }
        if (m.isEmpty) drinks.remove(pid);
        final prices = l.drinkPrices.containsKey(t.id)
            ? l.drinkPrices
            : {...l.drinkPrices, t.id: fallbackPrice};
        return l.copyWith(drinks: drinks, drinkPrices: prices);
      });

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final s = session;
    final types = store.drinkTypes.where((t) => t.active).toList();
    // Giá của buổi: ưu tiên giá đã lưu trong buổi, không có thì lấy theo ngày.
    int priceOf(DrinkType t) => s.drinkPrices[t.id] ?? t.priceOn(s.date);

    if (types.isEmpty) {
      return const EmptyHint('Chưa có loại nước.\nThêm ở Cài đặt → Loại nước & giá.',
          icon: Icons.local_drink_outlined);
    }
    if (s.playerIds.isEmpty) {
      return const EmptyHint('Chưa có người chơi trong buổi.\nChốt vote hoặc tick người chơi trước.',
          icon: Icons.people_outline);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Giá nước buổi này (bấm để sửa)',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final t in types)
                      ActionChip(
                        avatar: const Icon(Icons.local_drink, size: 16),
                        label: Text('${t.name}: ${vnd(priceOf(t))}'),
                        onPressed: () => _editPrice(context, t, priceOf(t)),
                      ),
                  ],
                ),
                if (s.settlement.totalDrinks > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Tổng tiền nước: ${vnd(s.settlement.totalDrinks)}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
        ),
        for (final pid in {...s.playerIds, ...s.drinks.keys})
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(store.playerName(pid),
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      Text(
                        (s.settlement.drinkPerPlayer[pid] ?? 0) == 0
                            ? ''
                            : '-${vnd(s.settlement.drinkPerPlayer[pid]!)}',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  for (final t in types)
                    Row(
                      children: [
                        Expanded(child: Text('${t.name} (${vnd(priceOf(t))})')),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: s.drinkQty(pid, t.id) == 0
                              ? null
                              : () => _changeQty(pid, t, -1, priceOf(t)),
                        ),
                        SizedBox(
                          width: 28,
                          child: Text('${s.drinkQty(pid, t.id)}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => _changeQty(pid, t, 1, priceOf(t)),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// =========================================================== SUMMARY TAB
class _SummaryTab extends StatelessWidget {
  const _SummaryTab({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final s = session;
    final st = s.settlement;
    final low = s.playerIds
        .where((pid) => store.balanceOf(pid) < store.settings.lowBalanceThreshold)
        .toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title.isEmpty ? 'Buổi chơi' : s.title,
                    style: Theme.of(context).textTheme.titleMedium),
                Text(fmtWeekday(s.date)),
                if (s.location.isNotEmpty) Text('📍 ${s.location}'),
                const Divider(),
                _row('Tiền sân', vnd(s.courtFee)),
                _row('Số người tính tiền', '${st.participants}'),
                _row('Mỗi đầu người', vnd(st.perHead)),
                _row('Quỹ chung trả', vnd(st.commonUsed)),
                if (st.guestCash > 0) _row('Khách trả tiền mặt', vnd(st.guestCash)),
                _row('Tổng tiền nước', vnd(st.totalDrinks)),
                if (s.note.isNotEmpty) ...[const Divider(), Text('📝 ${s.note}')],
                if (s.courtImageBase64 != null) ...[
                  const SizedBox(height: 8),
                  Base64Image(s.courtImageBase64!, height: 180),
                ],
              ],
            ),
          ),
        ),
        if (low.isNotEmpty)
          Card(
            color: Colors.orange.shade50,
            child: ListTile(
              leading: Icon(Icons.warning_amber, color: Colors.orange.shade800),
              title: const Text('Sắp hết quỹ sau buổi này'),
              subtitle: Text(low
                  .map((pid) => '${store.playerName(pid)} (${vnd(store.balanceOf(pid))})')
                  .join(', ')),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Từng người', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final pid in {...s.playerIds, ...s.drinks.keys})
          ListTile(
            dense: true,
            title: Text(store.playerName(pid)),
            subtitle: Text([
              if ((st.courtPerPlayer[pid] ?? 0) > 0) 'Sân ${vnd(st.courtPerPlayer[pid]!)}',
              if ((st.drinkPerPlayer[pid] ?? 0) > 0) 'Nước ${vnd(st.drinkPerPlayer[pid]!)}',
            ].join(' + ')),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('-${vnd((st.courtPerPlayer[pid] ?? 0) + (st.drinkPerPlayer[pid] ?? 0))}',
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                Text('còn ${vnd(store.balanceOf(pid))}', style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: () =>
                ShareService.shareText(context, ShareService.sessionReport(store, s)),
            icon: const Icon(Icons.share),
            label: const Text('Gửi tổng kết lên Zalo'),
          ),
        ),
      ],
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(k)),
            Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
