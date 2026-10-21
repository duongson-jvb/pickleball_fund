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
      ..sort((x, y) => (b[y.id] ?? 0).compareTo(b[x.id] ?? 0));
    final sb = StringBuffer('💰 SỐ DƯ QUỸ – ${store.settings.name}\n');
    sb.writeln('📅 ${fmtDate(DateTime.now())}');
    for (final p in players) {
      final bal = b[p.id] ?? 0;
      final warn = bal < store.settings.lowBalanceThreshold ? ' ⚠️' : '';
      sb.writeln('• ${p.name}: ${vnd(bal)}$warn');
    }
    sb.writeln('🏦 Quỹ chung: ${vnd(store.commonFund)}');
    return sb.toString();
  }

  static String lowBalanceReport(TeamStore store) {
    final low = store.lowBalancePlayers;
    if (low.isEmpty) return '✅ Không ai sắp hết quỹ.';
    final sb = StringBuffer(
        '⚠️ SẮP HẾT QUỸ (dưới ${vnd(store.settings.lowBalanceThreshold)})\n');
    for (final p in low) {
      sb.writeln('• ${p.name}: ${vnd(store.balanceOf(p.id))}');
    }
    sb.writeln('👉 Mọi người nộp thêm quỹ nhé!');
    if (store.settings.bankInfo.trim().isNotEmpty) {
      sb.writeln('🏦 ${store.settings.bankInfo.trim()}');
    }
    return sb.toString();
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
    sb.writeln('👥 ${s.playerIds.length} người chơi'
        '${s.guestCount > 0 ? ' + ${s.guestCount} khách' : ''}');
    if (s.courtFee > 0) {
      sb.writeln('💵 Tiền sân: ${vnd(s.courtFee)}'
          ' (${vnd(st.perHead)}/người)');
      if (st.commonUsed > 0) sb.writeln('   - Quỹ chung trả: ${vnd(st.commonUsed)}');
      if (st.guestCash > 0) sb.writeln('   - Khách trả tiền mặt: ${vnd(st.guestCash)}');
    }
    sb.writeln('—');
    for (final pid in s.playerIds) {
      final court = st.courtPerPlayer[pid] ?? 0;
      final drink = st.drinkPerPlayer[pid] ?? 0;
      final parts = <String>[];
      if (court > 0) parts.add('sân ${vnd(court)}');
      if (drink > 0) parts.add('nước ${vnd(drink)}');
      final detail = parts.isEmpty ? 'không trừ' : parts.join(' + ');
      sb.writeln('• ${store.playerName(pid)}: $detail'
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
    final sb = StringBuffer('📊 VOTE ĐẶT SÂN – ${fmtWeekday(s.date)}\n');
    if (s.title.isNotEmpty) sb.writeln('🏓 ${s.title}');
    if (s.location.isNotEmpty) sb.writeln('📍 ${s.location}');
    sb.writeln('👉 Ai đi thì vote nhé! Chốt danh sách trước giờ đặt sân.');
    final yes = s.votedYes;
    if (yes.isNotEmpty) {
      sb.writeln('\nĐã vote đi (${yes.length}):');
      for (final pid in yes) {
        sb.writeln('✅ ${store.playerName(pid)}');
      }
    }
    return sb.toString();
  }

  /// Phân tích kết quả vote copy từ Zalo: tìm tên người chơi xuất hiện
  /// trong văn bản. Trả về danh sách playerId khớp.
  static List<String> parseZaloVote(TeamStore store, String text) {
    final normalizedText = normalizeVi(text);
    final matched = <String>[];
    for (final p in store.activePlayers) {
      final name = normalizeVi(p.name);
      if (name.isEmpty) continue;
      if (normalizedText.contains(name)) {
        matched.add(p.id);
        continue;
      }
      // Thử khớp theo từng dòng với tên không dấu bỏ khoảng trắng.
      final compact = name.replaceAll(' ', '');
      for (final line in normalizedText.split('\n')) {
        if (line.replaceAll(' ', '').contains(compact)) {
          matched.add(p.id);
          break;
        }
      }
    }
    return matched;
  }
}
