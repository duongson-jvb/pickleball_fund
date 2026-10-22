import 'package:flutter/material.dart';

import '../../services/share_service.dart';
import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/admin_gate.dart';
import '../../widgets/common.dart';
import '../dashboard_screen.dart';
import '../fund/deposit_screen.dart';
import 'players_screen.dart';

/// Chi tiết một người chơi: số dư, lịch sử, nộp quỹ, điều chỉnh, xoá.
class PlayerDetailScreen extends StatelessWidget {
  const PlayerDetailScreen({super.key, required this.playerId});
  final String playerId;

  Future<void> _adjust(BuildContext context) async {
    if (!await requireAdmin(context) || !context.mounted) return;
    final store = TeamScope.of(context);
    final amount = TextEditingController();
    final note = TextEditingController();
    var minus = false;
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Điều chỉnh số dư'),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Cộng (+)')),
                    ButtonSegment(value: true, label: Text('Trừ (−)')),
                  ],
                  selected: {minus},
                  onSelectionChanged: (s) => setState(() => minus = s.first),
                ),
                const SizedBox(height: 12),
                AmountField(controller: amount, autofocus: true),
                const SizedBox(height: 12),
                TextFormField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Lý do'),
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
    if (ok == true) {
      final v = parseAmount(amount.text);
      await store.repo.adjust(
        playerId: playerId,
        amount: minus ? -v : v,
        note: note.text,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final player = store.playerById(playerId);
    if (player == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyHint('Người chơi đã bị xoá'));
    }
    final entries = store.ledgerOf(playerId);
    final bal = store.balanceOf(playerId);
    final deposited = entries
        .where((e) => e.amount > 0)
        .fold(0, (a, e) => a + e.amount);
    final spent = entries
        .where((e) => e.amount < 0)
        .fold(0, (a, e) => a + e.amount);

    return Scaffold(
      appBar: AppBar(
        title: Text(player.name),
        actions: [
          IconButton(
            tooltip: 'Chia sẻ số dư',
            icon: const Icon(Icons.share),
            onPressed: () => ShareService.shareText(
              context,
              '💰 ${player.name}: số dư quỹ ${vnd(bal)}'
              '${bal < store.settings.lowBalanceThreshold ? ' ⚠️ sắp hết, nộp thêm nhé!' : ''}'
              '${store.settings.bankInfo.isNotEmpty ? '\n🏦 ${store.settings.bankInfo}' : ''}',
            ),
          ),
          IconButton(
            tooltip: 'Sửa',
            icon: const Icon(Icons.edit),
            onPressed: () => showPlayerForm(context, player: player),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'adjust') {
                await _adjust(context);
              } else if (v == 'delete') {
                if (!await requireAdmin(context) || !context.mounted) return;
                final ok = await confirm(
                  context,
                  'Xoá ${player.name}?',
                  message: 'Toàn bộ lịch sử giao dịch của người này sẽ bị xoá. '
                      'Nếu chỉ tạm nghỉ, hãy tắt "Đang hoạt động" thay vì xoá.',
                );
                if (ok && context.mounted) {
                  await store.repo.deletePlayer(playerId);
                  if (context.mounted) Navigator.pop(context);
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'adjust', child: Text('Điều chỉnh số dư')),
              PopupMenuItem(value: 'delete', child: Text('Xoá người chơi')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DepositScreen(initialPlayerId: playerId)),
        ),
        icon: const Icon(Icons.add_card),
        label: const Text('Nộp quỹ'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text('Số dư hiện tại'),
                  MoneyText(bal,
                      warnBelow: store.settings.lowBalanceThreshold,
                      style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
                  if (bal < store.settings.lowBalanceThreshold)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('⚠️ Dưới ${vnd(store.settings.lowBalanceThreshold)}, cần nộp thêm',
                          style: TextStyle(color: Colors.orange.shade800)),
                    ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(children: [
                        const Text('Đã nộp', style: TextStyle(fontSize: 12)),
                        Text(vnd(deposited),
                            style: TextStyle(
                                fontWeight: FontWeight.bold, color: Colors.green.shade700)),
                      ]),
                      Column(children: [
                        const Text('Đã chi', style: TextStyle(fontSize: 12)),
                        Text(vnd(-spent),
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.error)),
                      ]),
                    ],
                  ),
                  if (player.phone.isNotEmpty || player.note.isNotEmpty) ...[
                    const Divider(height: 24),
                    Text([player.phone, player.note].where((s) => s.isNotEmpty).join(' · ')),
                  ],
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Lịch sử giao dịch', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (entries.isEmpty) const EmptyHint('Chưa có giao dịch'),
          for (final e in entries)
            LedgerTile(
              entry: e,
              showPlayer: false,
              onDelete: e.refId == null
                  ? () async {
                      if (!await requireAdmin(context) || !context.mounted) return;
                      if (await confirm(context, 'Xoá giao dịch này?')) {
                        await store.repo.deleteLedgerEntry(e.id);
                      }
                    }
                  : null,
            ),
        ],
      ),
    );
  }
}
