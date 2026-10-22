import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/admin_gate.dart';
import '../../widgets/common.dart';

/// Quản lý loại nước và lịch sử giá theo ngày.
class DrinkTypesScreen extends StatelessWidget {
  const DrinkTypesScreen({super.key});

  Future<void> _add(BuildContext context) async {
    if (!await requireAdmin(context) || !context.mounted) return;
    final store = TeamScope.of(context);
    final name = TextEditingController();
    final price = TextEditingController();
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Thêm loại nước'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Tên (VD: Revive, Nước suối)'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Nhập tên' : null,
              ),
              const SizedBox(height: 12),
              AmountField(controller: price, label: 'Giá hiện tại'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('Thêm'),
          ),
        ],
      ),
    );
    if (ok == true) await store.repo.addDrinkType(name.text, parseAmount(price.text));
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final types = store.drinkTypes;
    return Scaffold(
      appBar: AppBar(title: const Text('Loại nước & giá')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Icons.add),
        label: const Text('Thêm loại nước'),
      ),
      body: types.isEmpty
          ? const EmptyHint(
              'Chưa có loại nước.\nThêm các loại nước thường uống và giá để tính tiền nước mỗi buổi.',
              icon: Icons.local_drink_outlined)
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Giá nước áp dụng theo ngày: buổi chơi sẽ lấy giá của lần sửa gần nhất '
                    'trước ngày chơi. Bạn cũng có thể sửa giá riêng trong từng buổi.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                for (final t in types)
                  ListTile(
                    leading: Icon(Icons.local_drink,
                        color: t.active ? null : Colors.grey),
                    title: Text(t.name,
                        style: t.active
                            ? null
                            : const TextStyle(decoration: TextDecoration.lineThrough)),
                    subtitle: Text(
                      t.prices.isEmpty
                          ? 'Chưa có giá'
                          : 'Giá hiện tại ${vnd(t.latestPrice)} (từ ${fmtDate(t.prices.last.date)})',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => DrinkTypeDetailScreen(typeId: t.id)),
                    ),
                  ),
              ],
            ),
    );
  }
}

class DrinkTypeDetailScreen extends StatelessWidget {
  const DrinkTypeDetailScreen({super.key, required this.typeId});
  final String typeId;

  Future<void> _setPrice(BuildContext context, DrinkType t, {DrinkPrice? existing}) async {
    if (!await requireAdmin(context) || !context.mounted) return;
    final store = TeamScope.of(context);
    final price = TextEditingController(text: existing?.price.toString() ?? '');
    var date = existing?.date ?? DateTime.now();
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? 'Đổi giá ${t.name}' : 'Sửa giá ${t.name}'),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AmountField(controller: price, label: 'Giá mới', autofocus: true),
                DateTile(
                  label: 'Áp dụng từ ngày',
                  date: date,
                  onChanged: (d) => setState(() => date = d),
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
    if (ok == true) await store.repo.setDrinkPrice(t, date, parseAmount(price.text));
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final t = store.drinkTypeById(typeId);
    if (t == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyHint('Đã xoá'));
    }
    final history = t.prices.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(t.name),
        actions: [
          IconButton(
            tooltip: 'Đổi tên',
            icon: const Icon(Icons.edit),
            onPressed: () async {
              final ctrl = TextEditingController(text: t.name);
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Đổi tên'),
                  content: TextField(controller: ctrl, autofocus: true),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
                  ],
                ),
              );
              if (ok == true && ctrl.text.trim().isNotEmpty) {
                await store.repo.updateDrinkType(t, name: ctrl.text);
              }
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'toggle') {
                await store.repo.updateDrinkType(t, active: !t.active);
              } else if (v == 'delete') {
                if (await confirm(context, 'Xoá loại nước ${t.name}?',
                    message: 'Các buổi đã tính vẫn giữ nguyên số tiền.')) {
                  await store.repo.deleteDrinkType(t.id);
                  if (context.mounted) Navigator.pop(context);
                }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'toggle',
                  child: Text(t.active ? 'Ngưng bán' : 'Bán lại')),
              const PopupMenuItem(value: 'delete', child: Text('Xoá')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _setPrice(context, t),
        icon: const Icon(Icons.price_change),
        label: const Text('Đổi giá'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          Card(
            child: ListTile(
              title: const Text('Giá hiện tại'),
              trailing: Text(vnd(t.latestPrice),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Lịch sử giá', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final p in history)
            ListTile(
              dense: true,
              leading: const Icon(Icons.history),
              title: Text(vnd(p.price)),
              subtitle: Text('Áp dụng từ ${fmtDate(p.date)}'),
              trailing: const Icon(Icons.edit, size: 18),
              onTap: () => _setPrice(context, t, existing: p),
            ),
        ],
      ),
    );
  }
}
