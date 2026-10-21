import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/settlement.dart';
import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

/// Thêm / sửa chi phí khác.
class ExpenseFormScreen extends StatefulWidget {
  const ExpenseFormScreen({super.key, this.expense});
  final Expense? expense;

  @override
  State<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends State<ExpenseFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late DateTime _date;
  late bool _forAll;
  late Set<String> _selected;
  int _parsed = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.expense;
    _title = TextEditingController(text: e?.title ?? '');
    _amount = TextEditingController(text: e == null ? '' : e.amount.toString());
    _note = TextEditingController(text: e?.note ?? '');
    _date = e?.date ?? DateTime.now();
    _forAll = e?.isForEveryone ?? true;
    _selected = {...?e?.playerIds};
    _parsed = e?.amount ?? 0;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (!_forAll && _selected.isEmpty) {
      showSnack(context, 'Chọn ít nhất một người hoặc chọn "Tất cả"');
      return;
    }
    final store = TeamScope.of(context);
    setState(() => _busy = true);
    try {
      final id = widget.expense?.id ?? '';
      final expense = Expense(
        id: id,
        title: _title.text.trim(),
        amount: parseAmount(_amount.text),
        date: _date,
        playerIds: _forAll ? const [] : _selected.toList(),
        note: _note.text.trim(),
        createdAt: widget.expense?.createdAt ?? DateTime.now(),
      );
      await store.repo.saveAndSettleExpense(
        expense,
        allActivePlayerIds: store.activePlayers.map((p) => p.id).toList(),
        commonFundExcludingThis: id.isEmpty ? store.commonFund : store.commonFundExcluding(id),
      );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final players = store.activePlayers;
    final id = widget.expense?.id ?? '';
    final commonAvail = id.isEmpty ? store.commonFund : store.commonFundExcluding(id);
    final preview = Settlement.computeExpense(
      expense: Expense(
        id: id,
        title: '',
        amount: _parsed,
        date: _date,
        playerIds: _forAll ? const [] : _selected.toList(),
        createdAt: DateTime.now(),
      ),
      allActivePlayerIds: players.map((p) => p.id).toList(),
      commonFundAvailable: commonAvail,
    );
    final perHead = preview.perPlayer.values.isEmpty
        ? 0
        : preview.perPlayer.values.reduce((a, b) => a > b ? a : b);

    return Scaffold(
      appBar: AppBar(title: Text(widget.expense == null ? 'Thêm chi phí' : 'Sửa chi phí')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _title,
              autofocus: widget.expense == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Tên chi phí * (VD: Mua bóng)'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Nhập tên chi phí' : null,
            ),
            const SizedBox(height: 12),
            AmountField(controller: _amount, onChanged: (v) => setState(() => _parsed = v)),
            DateTile(date: _date, onChanged: (d) => setState(() => _date = d)),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Tất cả mọi người'), icon: Icon(Icons.groups)),
                ButtonSegment(value: false, label: Text('Chọn người'), icon: Icon(Icons.checklist)),
              ],
              selected: {_forAll},
              onSelectionChanged: (s) => setState(() => _forAll = s.first),
            ),
            const SizedBox(height: 8),
            if (_forAll)
              Text(
                'Chia cho ${players.length} người đang hoạt động, ưu tiên trừ quỹ chung '
                '(đang có ${vnd(commonAvail)}).',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              PlayerMultiSelect(
                players: players,
                selected: _selected,
                balances: store.balances,
                onChanged: (s) => setState(() => _selected = s),
              ),
            const SizedBox(height: 12),
            if (_parsed > 0)
              Card(
                margin: EdgeInsets.zero,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Dự tính', style: TextStyle(fontWeight: FontWeight.bold)),
                      if (preview.commonUsed > 0)
                        Text('• Quỹ chung trả: ${vnd(preview.commonUsed)}'),
                      if (preview.perPlayer.isNotEmpty)
                        Text('• Mỗi người trừ: ~${vnd(perHead)} (${preview.perPlayer.length} người)'),
                      if (preview.perPlayer.isEmpty && preview.commonUsed > 0)
                        const Text('• Quỹ chung đủ trả, không ai bị trừ'),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Ghi chú'),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Lưu & trừ quỹ'),
            ),
          ],
        ),
      ),
    );
  }
}
