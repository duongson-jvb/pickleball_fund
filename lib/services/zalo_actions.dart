import 'dart:convert';

import 'package:http/http.dart' as http;

import 'share_service.dart';
import 'team_store.dart';
import 'zalo_bot_service.dart';

/// Các việc bot làm theo lệnh từ app: giục nạp quỹ (kèm QR), báo kết quả vote.
/// Có webhook thì nhờ webhook (gửi được ảnh QR qua URL công khai); không thì
/// app tự gửi chữ qua Zalo Bot API.
class ZaloActions {
  ZaloActions._();

  static Future<String> remindLowBalance(TeamStore store) async {
    final s = store.settings;
    if (!s.hasZaloBot) throw Exception('Chưa cấu hình Zalo Bot (Cài đặt → Zalo Bot).');
    if (s.zaloGroupId.isEmpty) throw Exception('Chưa chọn nhóm Zalo (Cài đặt → Zalo Bot).');
    if (s.zaloWebhookUrl.isNotEmpty) {
      final r = await _call(store, 'remind');
      final remind = r['remind'] as Map<String, dynamic>? ?? {};
      final status = remind['status']?.toString() ?? '';
      if (!status.startsWith('sent')) throw Exception('Bot không gửi được: $status');
      final low = remind['low'];
      final qr = remind['qr']?.toString();
      return 'Đã nhắc ${low ?? 0} người sắp hết quỹ lên Zalo'
          '${qr == null ? '' : qr == 'sent' ? ' kèm QR' : ' (QR lỗi: $qr)'}';
    }
    await ZaloBotService.forTeam(s, store.repo.teamId)
        .sendMessage(s.zaloGroupId, ShareService.lowBalanceReport(store));
    return 'Đã nhắc lên Zalo (không gửi được ảnh QR vì chưa có webhook)';
  }

  static Future<Map<String, dynamic>> _call(TeamStore store, String action,
      {Map<String, String> params = const {}}) async {
    final s = store.settings;
    final base = ZaloBotService.normalizeWorkerUrl(s.zaloWebhookUrl, store.repo.teamId);
    final uri = Uri.parse(base).replace(queryParameters: {'action': action, ...params});
    final res = await http.post(uri, headers: {'X-Bot-Api-Secret-Token': s.zaloWebhookSecret});
    if (res.statusCode != 200) {
      throw Exception('Webhook trả ${res.statusCode}: ${res.body.length > 120 ? res.body.substring(0, 120) : res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
