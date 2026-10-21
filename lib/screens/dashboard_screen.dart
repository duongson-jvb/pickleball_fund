import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/share_service.dart';
import '../services/team_store.dart';
import '../utils/format.dart';
import '../widgets/common.dart';
import 'fund/common_fund_screen.dart';
import 'fund/deposit_screen.dart';
import 'settings/qr_screen.dart';
import 'share/share_screen.dart';

/// Tổng quan: số dư, cảnh báo sắp hết quỹ, thao tác nhanh, giao dịch gần đây.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final low = store.lowBalancePlayers;
    final recent = store.ledger.take(15).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(store.settings.name),
        actions: [
          IconButton(
            tooltip: 'Chia sẻ lên Zalo',
            icon: const Icon(Icons.share),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ShareScreen())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: _StatCard(
                    title: 'Quỹ chung',
                    value: vnd(store.commonFund),
                    icon: Icons.account_balance,
                    color: Colors.teal,
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const CommonFundScreen())),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatCard(
                    title: 'Tổng quỹ cá nhân',
                    value: vnd(store.totalPlayerBalance),
                    icon: Icons.savings,
                    color: Colors.indigo,
                    subtitle: '${store.activePlayers.length} người',
                  ),
                ),
              ],
            ),
          ),
          if (low.isNotEmpty)
            Card(
              color: Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning_amber, color: Colors.orange.shade800),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Sắp hết quỹ (dưới ${vnd(store.settings.lowBalanceThreshold)})',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Nhắc lên Zalo',
                          icon: const Icon(Icons.share),
                          onPressed: () => ShareService.shareText(
                              context, ShareService.lowBalanceReport(store)),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final p in low)
                          Chip(
                            avatar: const Icon(Icons.person, size: 16),
                            label: Text('${p.name}: ${vnd(store.balanceOf(p.id))}'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const DepositScreen())),
                  icon: const Icon(Icons.add_card),
                  label: const Text('Nộp quỹ'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const CommonFundScreen())),
                  icon: const Icon(Icons.account_balance),
                  label: const Text('Quỹ chung'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const QrScreen())),
                  icon: const Icon(Icons.qr_code),
                  label: const Text('QR chuyển khoản'),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Số dư từng người',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          Card(
            child: Column(
              children: [
                for (final p in (store.activePlayers.toList()
                  ..sort((a, b) =>
                      store.balanceOf(a.id).compareTo(store.balanceOf(b.id)))))
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(
                        radius: 16,
                        child: Text(p.name.isEmpty ? '?' : p.name[0].toUpperCase())),
                    title: Text(p.name),
                    trailing: MoneyText(store.balanceOf(p.id),
                        warnBelow: store.settings.lowBalanceThreshold),
                  ),
                if (store.activePlayers.isEmpty)
                  const ListTile(title: Text('Chưa có người chơi. Thêm ở tab Người chơi.')),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Giao dịch gần đây',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          Card(
            child: Column(
              children: [
                if (recent.isEmpty)
                  const ListTile(title: Text('Chưa có giao dịch')),
                for (final e in recent) LedgerTile(entry: e),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    this.subtitle,
    this.onTap,
  });
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 6),
                Expanded(child: Text(title, style: const TextStyle(fontSize: 12))),
              ]),
              const SizedBox(height: 6),
              Text(value,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold, color: color)),
              if (subtitle != null)
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// Một dòng sổ quỹ.
class LedgerTile extends StatelessWidget {
  const LedgerTile({super.key, required this.entry, this.showPlayer = true, this.onDelete});
  final LedgerEntry entry;
  final bool showPlayer;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final who = entry.isCommonFund ? 'Quỹ chung' : store.playerName(entry.playerId!);
    final icon = switch (entry.type) {
      LedgerType.deposit || LedgerType.commonIn => Icons.arrow_downward,
      LedgerType.court => Icons.sports_tennis,
      LedgerType.drink => Icons.local_drink,
      LedgerType.expense || LedgerType.commonOut => Icons.shopping_bag,
      LedgerType.adjust => Icons.tune,
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20),
      title: Text(showPlayer ? '$who · ${entry.type.label}' : entry.type.label),
      subtitle: Text(
        [fmtDate(entry.date), if (entry.note.isNotEmpty) entry.note].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MoneyText(entry.amount, signed: true),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}
