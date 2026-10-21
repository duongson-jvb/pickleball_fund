import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'session_detail_screen.dart';
import 'session_form_screen.dart';

/// Danh sách buổi chơi.
class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final sessions = store.sessions;
    return Scaffold(
      appBar: AppBar(title: const Text('Buổi chơi')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const SessionFormScreen())),
        icon: const Icon(Icons.add),
        label: const Text('Tạo buổi / vote'),
      ),
      body: sessions.isEmpty
          ? const EmptyHint(
              'Chưa có buổi chơi.\nTạo buổi mới để vote người chơi, nhập tiền sân và tiền nước.',
              icon: Icons.sports_tennis_outlined)
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: sessions.length,
              itemBuilder: (context, i) => _SessionTile(session: sessions[i]),
            ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final voting = s.status == SessionStatus.voting;
    final st = s.settlement;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: voting ? Colors.orange.shade100 : Colors.teal.shade100,
          child: Icon(voting ? Icons.how_to_vote : Icons.sports_tennis,
              color: voting ? Colors.orange.shade800 : Colors.teal.shade800),
        ),
        title: Text(s.title.isEmpty ? fmtWeekday(s.date) : s.title),
        subtitle: Text([
          fmtWeekday(s.date),
          if (s.location.isNotEmpty) s.location,
          voting
              ? 'Đang vote: ${s.votedYes.length} người đi'
              : '${s.playerIds.length} người${s.guestCount > 0 ? ' + ${s.guestCount} khách' : ''}',
          if (s.courtFee > 0) 'Sân ${vnd(s.courtFee)}',
          if (st.totalDrinks > 0) 'Nước ${vnd(st.totalDrinks)}',
        ].join(' · ')),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s.courtImageBase64 != null) const Icon(Icons.image, size: 18),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SessionDetailScreen(sessionId: s.id)),
        ),
      ),
    );
  }
}
