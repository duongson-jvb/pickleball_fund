import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/share_service.dart';
import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'expense_form_screen.dart';

/// Chi phí khác: mua bóng, quần áo...
class ExpensesScreen extends StatelessWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final list = store.expenses;
    return Scaffold(
      appBar: AppBar(title: const Text('Chi phí khác')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const ExpenseFormScreen())),
        icon: const Icon(Icons.add),
        label: const Text('Thêm chi phí'),
      ),
      body: list.isEmpty
          ? const EmptyHint(
              'Chưa có chi phí.\nVD: mua bóng, in áo... Không chọn ai = chia cho tất cả, '
              'ưu tiên dùng quỹ chung.',
              icon: Icons.receipt_long_outlined)
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: list.length,
              itemBuilder: (context, i) => _ExpenseTile(expense: list[i]),
            ),
    );
  }
}

class _ExpenseTile extends StatelessWidget {
  const _ExpenseTile({required this.expense});
  final Expense expense;

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final e = expense;
    final who = e.isForEveryone
        ? 'Tất cả (${e.perPlayer.length} người)'
        : e.playerIds.map(store.playerName).join(', ');
    return Card(
      child: ListTile(
        leading: const Icon(Icons.shopping_bag_outlined),
        title: Text(e.title),
        subtitle: Text([
          fmtDate(e.date),
          who,
          if (e.commonUsed > 0) 'Quỹ chung trả ${vnd(e.commonUsed)}',
        ].join(' · ')),
        trailing: Text(vnd(e.amount),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        isThreeLine: true,
        onTap: () => showModalBottomSheet(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(e.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(ShareService.expenseReport(store, e)),
                ),
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Sửa'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => ExpenseFormScreen(expense: e)));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share),
                  title: const Text('Chia sẻ lên Zalo'),
                  onTap: () {
                    Navigator.pop(ctx);
                    ShareService.shareText(context, ShareService.expenseReport(store, e));
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete, color: Theme.of(ctx).colorScheme.error),
                  title: const Text('Xoá (hoàn tiền lại cho mọi người)'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    if (await confirm(context, 'Xoá chi phí "${e.title}"?')) {
                      await store.repo.deleteExpense(e.id);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
