import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/team_store.dart';
import '../../widgets/admin_gate.dart';
import '../../widgets/common.dart';
import 'player_detail_screen.dart';

/// Danh sách người chơi: thêm / sửa / xoá.
class PlayersScreen extends StatelessWidget {
  const PlayersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final players = store.players.toList()
      ..sort((a, b) {
        if (a.active != b.active) return a.active ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return Scaffold(
      appBar: AppBar(title: Text('Người chơi (${store.activePlayers.length})')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab-players',
        onPressed: () => showPlayerForm(context),
        icon: const Icon(Icons.person_add),
        label: const Text('Thêm'),
      ),
      body: players.isEmpty
          ? const EmptyHint('Chưa có người chơi.\nBấm "Thêm" để tạo thành viên đầu tiên.',
              icon: Icons.people_outline)
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: players.length,
              itemBuilder: (context, i) {
                final p = players[i];
                final bal = store.balanceOf(p.id);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: p.active ? null : Colors.grey.shade300,
                    child: Text(p.name.isEmpty ? '?' : p.name[0].toUpperCase()),
                  ),
                  title: Text(p.name,
                      style: p.active
                          ? null
                          : const TextStyle(decoration: TextDecoration.lineThrough)),
                  subtitle: Text([
                    if (p.phone.isNotEmpty) p.phone,
                    if (!p.active) 'Ngưng hoạt động',
                    if (p.note.isNotEmpty) p.note,
                  ].join(' · ')),
                  trailing: MoneyText(bal, warnBelow: store.settings.lowBalanceThreshold),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => PlayerDetailScreen(playerId: p.id)),
                  ),
                );
              },
            ),
    );
  }
}

/// Form thêm / sửa người chơi.
Future<void> showPlayerForm(BuildContext context, {Player? player}) async {
  if (!await requireAdmin(context) || !context.mounted) return;
  final store = TeamScope.of(context);
  final name = TextEditingController(text: player?.name ?? '');
  final phone = TextEditingController(text: player?.phone ?? '');
  final note = TextEditingController(text: player?.note ?? '');
  var active = player?.active ?? true;
  final form = GlobalKey<FormState>();

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(player == null ? 'Thêm người chơi' : 'Sửa người chơi'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Tên *'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Nhập tên' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Số điện thoại / Zalo'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: note,
                decoration: const InputDecoration(labelText: 'Ghi chú'),
              ),
              if (player != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Đang hoạt động'),
                  subtitle: const Text('Tắt nếu tạm nghỉ, sẽ không bị chia tiền chung'),
                  value: active,
                  onChanged: (v) => setState(() => active = v),
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
  if (player == null) {
    await store.repo.addPlayer(name.text, phone: phone.text, note: note.text);
  } else {
    await store.repo.updatePlayer(player.id, {
      'name': name.text.trim(),
      'phone': phone.text.trim(),
      'note': note.text.trim(),
      'active': active,
    });
  }
}
