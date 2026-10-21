import 'package:flutter/material.dart';

import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../dashboard_screen.dart';

/// Quỹ chung: nộp tiền vào quỹ chung và xem lịch sử sử dụng.
class CommonFundScreen extends StatelessWidget {
  const CommonFundScreen({super.key});

  Future<void> _addFunds(BuildContext context) async {
    final store = TeamScope.of(context);
    final amount = TextEditingController();
    final note = TextEditingController();
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nộp vào quỹ chung'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AmountField(controller: amount, autofocus: true),
              const SizedBox(height: 12),
              TextFormField(
                controller: note,
                decoration: const InputDecoration(labelText: 'Ghi chú (nguồn tiền...)'),
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
            child: const Text('Nộp'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await store.repo.addCommonFund(amount: parseAmount(amount.text), note: note.text);
      if (context.mounted) showSnack(context, 'Đã nộp quỹ chung');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final entries = store.commonFundLedger;
    return Scaffold(
      appBar: AppBar(title: const Text('Quỹ chung')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addFunds(context),
        icon: const Icon(Icons.add),
        label: const Text('Nộp quỹ chung'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text('Số dư quỹ chung'),
                  const SizedBox(height: 4),
                  Text(vnd(store.commonFund),
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    'Quỹ chung được ưu tiên dùng trả tiền sân và các chi phí tính cho '
                    'tất cả mọi người. Khi hết quỹ chung, phần thiếu chia đều cho người chơi.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Lịch sử', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (entries.isEmpty) const EmptyHint('Chưa có giao dịch quỹ chung'),
          for (final e in entries)
            LedgerTile(
              entry: e,
              showPlayer: false,
              // Chỉ cho xoá các khoản nộp thủ công; khoản chi tự động gắn với
              // buổi chơi / chi phí sẽ được tính lại khi sửa buổi đó.
              onDelete: e.refId == null
                  ? () async {
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
