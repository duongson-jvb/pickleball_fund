import 'package:flutter/material.dart';

import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/admin_gate.dart';
import '../../widgets/common.dart';

/// Nộp quỹ: cho một người, hoặc cho tất cả (chia đều theo đầu người).
class DepositScreen extends StatefulWidget {
  const DepositScreen({super.key, this.initialPlayerId});
  final String? initialPlayerId;

  @override
  State<DepositScreen> createState() => _DepositScreenState();
}

class _DepositScreenState extends State<DepositScreen> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String? _playerId; // null = tất cả
  bool _forAll = false;
  DateTime _date = DateTime.now();
  bool _busy = false;
  int _parsed = 0;

  @override
  void initState() {
    super.initState();
    _playerId = widget.initialPlayerId;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (!await requireAdmin(context) || !mounted) return;
    final store = TeamScope.of(context);
    final amount = parseAmount(_amount.text);
    if (!_forAll && _playerId == null) {
      showSnack(context, 'Chọn người nộp hoặc chọn "Tất cả"');
      return;
    }
    setState(() => _busy = true);
    try {
      if (_forAll) {
        await store.repo.depositForAll(
          amount: amount,
          playerIds: store.activePlayers.map((p) => p.id).toList(),
          note: _note.text,
          date: _date,
        );
      } else {
        await store.repo.deposit(
          playerId: _playerId!,
          amount: amount,
          note: _note.text,
          date: _date,
        );
      }
      if (mounted) {
        showSnack(context, 'Đã cập nhật quỹ');
        Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final players = store.activePlayers;
    final perHead = (_forAll && players.isNotEmpty) ? _parsed ~/ players.length : 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Nộp quỹ')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Một người'), icon: Icon(Icons.person)),
                ButtonSegment(value: true, label: Text('Tất cả (chia đều)'), icon: Icon(Icons.groups)),
              ],
              selected: {_forAll},
              onSelectionChanged: (s) => setState(() => _forAll = s.first),
            ),
            const SizedBox(height: 16),
            if (!_forAll)
              DropdownButtonFormField<String>(
                initialValue: _playerId,
                decoration: const InputDecoration(labelText: 'Người nộp'),
                items: [
                  for (final p in players)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text('${p.name}  (${vnd(store.balanceOf(p.id))})'),
                    ),
                ],
                onChanged: (v) => setState(() => _playerId = v),
                validator: (v) => (!_forAll && v == null) ? 'Chọn người nộp' : null,
              ),
            if (_forAll)
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Số tiền sẽ chia đều cho ${players.length} người đang hoạt động'
                    '${perHead > 0 ? ': mỗi người ${vnd(perHead)}' : ''}.',
                  ),
                ),
              ),
            const SizedBox(height: 16),
            AmountField(
              controller: _amount,
              autofocus: true,
              onChanged: (v) => setState(() => _parsed = v),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Ghi chú (tuỳ chọn)'),
            ),
            DateTile(date: _date, onChanged: (d) => setState(() => _date = d)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Cập nhật quỹ'),
            ),
          ],
        ),
      ),
    );
  }
}
