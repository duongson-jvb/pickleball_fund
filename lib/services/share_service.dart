import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../utils/format.dart';
import '../utils/text.dart';
import 'image_util.dart';
import 'team_store.dart';

/// Tạo nội dung văn bản và chia sẻ (Zalo, Messenger... qua share sheet).
class ShareService {
  ShareService._();

  static Future<void> shareText(BuildContext context, String text,
      {String? subject}) async {
    final box = context.findRenderObject() as RenderBox?;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await SharePlus.instance.share(ShareParams(
        text: text,
        subject: subject,
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (_) {
      // Trình duyệt desktop không có share sheet: sao chép để dán vào Zalo.
      await Clipboard.setData(ClipboardData(text: text));
      messenger?.showSnackBar(
          const SnackBar(content: Text('Đã sao chép nội dung, dán vào Zalo')));
    }
  }

  static Future<void> shareImageBase64(
    BuildContext context,
    String base64, {
    String fileName = 'image.jpg',
    String? text,
  }) async {
    final box = context.findRenderObject() as RenderBox?;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final Uint8List bytes = ImageUtil.decode(base64);
    try {
      await SharePlus.instance.share(ShareParams(
        text: text,
        files: [XFile.fromData(bytes, mimeType: 'image/jpeg', name: fileName)],
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (_) {
      if (text != null && text.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
      }
      messenger?.showSnackBar(const SnackBar(
          content: Text('Thiết bị không chia sẻ được ảnh. Hãy lưu ảnh QR rồi gửi thủ công.')));
    }
  }

  // ----------------------------------------------------------- templates
  static String balanceReport(TeamStore store) {
    final b = store.balances;
    final players = store.activePlayers.toList()
      ..sort((x, y) => (b[x.id] ?? 0).compareTo(b[y.id] ?? 0));
    final th = store.settings.lowBalanceThreshold;
    final low = players.where((p) => (b[p.id] ?? 0) < th).toList();
    final bank = store.settings.bankInfo.trim();
    final blocks = [
      '💰 QUỸ NHÓM · ${store.settings.name} (${fmtDate(DateTime.now())})',
      '🏦 Quỹ chung: ${vnd(store.commonFund)}',
      low.isEmpty
          ? '✅ Ai cũng còn quỹ, chưa ai cần nạp.'
          : [
              '⚠️ CẦN NẠP THÊM (dưới ${vnd(th)})',
              for (final p in low) '• ${p.name}: ${vnd(b[p.id] ?? 0)}',
              if (bank.isNotEmpty) '🏦 ${bank.split('\n').map((e) => e.trim()).join(' · ')}',
            ].join('\n'),
      [
        '📋 SỐ DƯ TỪNG NGƯỜI',
        for (final p in players) '• ${p.name}: ${vnd(b[p.id] ?? 0)}${(b[p.id] ?? 0) < th ? ' ⚠️' : ''}',
      ].join('\n'),
    ];
    return blocks.join('\n\n');
  }

  static String lowBalanceReport(TeamStore store) {
    final low = store.lowBalancePlayers;
    if (low.isEmpty) return '✅ Không ai sắp hết quỹ.';
    final bank = store.settings.bankInfo.trim();
    return [
      '📣 NHẮC NẠP QUỸ · ${store.settings.name}',
      [
        '⚠️ CẦN NẠP THÊM (dưới ${vnd(store.settings.lowBalanceThreshold)})',
        for (final p in low) '• ${p.name}: ${vnd(store.balanceOf(p.id))}',
      ].join('\n'),
      '👉 Chuyển khoản rồi nhắn quản lý ghi nhận giúp em nhé!'
          '${bank.isNotEmpty ? '\n🏦 ${bank.split('\n').map((e) => e.trim()).join(' · ')}' : ''}',
    ].join('\n\n');
  }

  static String commonFundReport(TeamStore store) =>
      '🏦 Quỹ chung hiện có: ${vnd(store.commonFund)}';

  static String bankInfo(TeamStore store) =>
      store.settings.bankInfo.trim().isEmpty
          ? ''
          : '🏦 Chuyển khoản: ${store.settings.bankInfo.trim()}';

  static String sessionReport(TeamStore store, Session s) {
    final st = s.settlement;
    final sb = StringBuffer('🏓 ${s.title.isEmpty ? 'BUỔI CHƠI' : s.title.toUpperCase()}\n');
    sb.writeln('📅 ${fmtWeekday(s.date)}');
    if (s.location.isNotEmpty) sb.writeln('📍 ${s.location}');
    // Đếm cả người đính kèm, nếu không thì dòng này nói "2 người chơi" trong khi
    // tiền sân chia cho 4 suất - người đọc không hiểu vì sao có người trả gấp đôi.
    sb.writeln('👥 ${s.playerIds.length} người chơi'
        '${s.totalCompanions > 0 ? ' + ${s.totalCompanions} đính kèm' : ''}'
        '${s.guestCount > 0 ? ' + ${s.guestCount} khách' : ''}');
    if (s.courtFee > 0) {
      sb.writeln('💵 Tiền sân: ${vnd(s.courtFee)}'
          ' (${vnd(st.perHead)}/người)');
      if (st.commonUsed > 0) sb.writeln('   - Quỹ chung trả: ${vnd(st.commonUsed)}');
      if (st.guestCash > 0) sb.writeln('   - Khách trả tiền mặt: ${vnd(st.guestCash)}');
    }
    sb.writeln('\n💳 TRỪ QUỸ TỪNG NGƯỜI');
    // Gồm cả người không trong danh sách chơi nhưng có ghi nước (nhập hộ qua Zalo).
    // Người đính kèm ("<id>#n") đã gộp tiền vào người vote nên không liệt kê riêng.
    final pids = {...s.playerIds, ...s.drinks.keys}.where((k) => !Session.isCompanionId(k));
    for (final pid in pids) {
      final court = st.courtPerPlayer[pid] ?? 0;
      final drink = st.drinkPerPlayer[pid] ?? 0;
      final parts = <String>[];
      if (court > 0) parts.add('sân ${vnd(court)}');
      if (drink > 0) parts.add('nước ${vnd(drink)}');
      final detail = parts.isEmpty ? 'không trừ' : parts.join(' + ');
      final comp = s.companionsOf(pid);
      sb.writeln('• ${store.playerName(pid)}${comp > 0 ? ' (+$comp đính kèm)' : ''}: $detail'
          ' → còn ${vnd(store.balanceOf(pid))}');
    }
    if (s.note.isNotEmpty) sb.writeln('📝 ${s.note}');
    return sb.toString();
  }

  static String expenseReport(TeamStore store, Expense e) {
    final sb = StringBuffer('🧾 ${e.title.toUpperCase()} – ${vnd(e.amount)}\n');
    sb.writeln('📅 ${fmtDate(e.date)}');
    if (e.commonUsed > 0) sb.writeln('🏦 Quỹ chung trả: ${vnd(e.commonUsed)}');
    e.perPlayer.forEach((pid, amt) {
      sb.writeln('• ${store.playerName(pid)}: ${vnd(amt)}');
    });
    if (e.note.isNotEmpty) sb.writeln('📝 ${e.note}');
    return sb.toString();
  }

  /// Nội dung vote gửi lên Zalo.
  static String voteText(TeamStore store, Session s) {
    // Bố cục: việc chính (buổi nào, lúc nào) → điều kiện vote → ai đã vote → cách vote.
    // Mỗi khối cách nhau một dòng trống để lướt qua là đọc được trên Zalo.
    final head = [
      '📊 VOTE ĐẶT SÂN · ${s.title.isEmpty ? fmtWeekday(s.date) : s.title}',
      '🕕 ${fmtWeekday(s.date)} · ${_hm(s.date)}',
      if (s.location.isNotEmpty) '📍 ${s.location}',
    ].join('\n');
    final rules = [
      '⏰ Hạn vote: ${fmtDateTime(s.effectiveVoteDeadline)}',
      s.maxPlayers != null ? '👥 Giới hạn: ${s.maxPlayers} suất' : '👥 Không giới hạn số người',
      if (s.createdByName.isNotEmpty) '👤 Người tạo: ${s.createdByName}',
    ].join('\n');
    // Liệt kê đúng những người đang giữ chỗ (gồm cả người quản lý thêm thẳng
    // vào danh sách), để số ở tiêu đề khớp với số dòng bên dưới.
    final holders = s.seatHolders;
    final added = s.addedWithoutVote.toSet();
    final voted = holders.isEmpty
        ? '✅ Chưa ai vote'
        : [
            '✅ ĐÃ CÓ CHỖ (${s.seatsTaken}${s.maxPlayers != null ? '/${s.maxPlayers}' : ''} suất)',
            for (final pid in holders)
              '• ${store.playerName(pid)}'
              '${s.companionsOf(pid) > 0 ? ' (+${s.companionsOf(pid)})' : ''}'
              '${added.contains(pid) ? ' · quản lý thêm' : ''}',
          ].join('\n');
    const guide = '👉 Reply tin này: 1 = đi · 2 = đi 2 người · 0 = không · "@An 1" vote hộ\n'
        '📌 Quản lý ghim tin này cho dễ thấy. Hết hạn bot tự báo kết quả.';
    return [head, rules, voted, guide].join('\n\n');
  }

  /// Kết quả vote khi hết hạn (app gửi ở chế độ không webhook; webhook tự gửi khi có).
  static String voteResultText(TeamStore store, Session s) {
    final holders = s.seatHolders;
    final added = s.addedWithoutVote.toSet();
    // Người quản lý đã đưa vào danh sách chơi thì coi như có đi, dù vote cũ là
    // "không" - nếu không họ sẽ xuất hiện ở cả hai danh sách trong một tin.
    final no = s.votes.entries
        .where((e) => !e.value && !s.playerIds.contains(e.key))
        .map((e) => store.playerName(e.key))
        .toList();
    final cap = s.maxPlayers != null ? '/${s.maxPlayers}' : '';
    final blocks = [
      '🔒 HẾT HẠN VOTE · ${s.title.isEmpty ? fmtWeekday(s.date) : s.title}',
      '🕕 ${fmtWeekday(s.date)} · ${_hm(s.date)}${s.location.isNotEmpty ? '\n📍 ${s.location}' : ''}',
      holders.isEmpty
          ? '😢 Chưa có ai vote đi.'
          : [
              '✅ ĐI (${s.seatsTaken}$cap suất)',
              for (final pid in holders)
                '• ${store.playerName(pid)}'
                '${s.companionsOf(pid) > 0 ? ' (+${s.companionsOf(pid)} đính kèm)' : ''}'
                '${added.contains(pid) ? ' · quản lý thêm' : ''}',
            ].join('\n'),
      if (no.isNotEmpty) '❌ Không đi: ${no.join(', ')}',
      if (s.maxPlayers != null && s.seatsTaken > s.maxPlayers!)
        '⚠️ Vượt ${s.seatsTaken - s.maxPlayers!} suất so với giới hạn, quản lý chốt danh sách trong app.',
      '📌 Quản lý bỏ ghim tin vote giúp em nhé. Danh sách chính thức xem trong app.',
    ];
    return blocks.join('\n\n');
  }

  static String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// Phân tích kết quả vote copy từ Zalo: tìm tên người chơi xuất hiện
  /// trong văn bản. Trả về danh sách playerId khớp.
  static List<String> parseZaloVote(TeamStore store, String text) {
    final normalizedText = normalizeVi(text);
    final matched = <String>[];
    for (final p in store.activePlayers) {
      final name = normalizeVi(p.name);
      if (name.isEmpty) continue;
      // Khớp trọn cụm từ: tên "An" không được khớp vào "Hoàng Văn Bình".
      if (containsWholeWord(normalizedText, name)) {
        matched.add(p.id);
        continue;
      }
      // Tên viết liền không dấu chiếm trọn một dòng: "nguyenvanan".
      final compact = name.replaceAll(' ', '');
      for (final line in normalizedText.split('\n')) {
        if (line.replaceAll(RegExp(r'[^a-z0-9]'), '') == compact) {
          matched.add(p.id);
          break;
        }
      }
    }
    return matched;
  }
}
