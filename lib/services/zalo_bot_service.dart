import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../models/models.dart';

/// Thông tin bot trả về từ getMe.
class ZaloBotInfo {
  final String id;
  final String displayName;
  final bool canJoinGroups;
  const ZaloBotInfo({
    required this.id,
    required this.displayName,
    required this.canJoinGroups,
  });
}

/// Một tin nhắn bot nhận được (từ getUpdates / webhook).
class ZaloUpdate {
  final String eventName;
  final String messageId;
  final String fromId;
  final String fromName;
  final String chatId;
  final String chatType; // PRIVATE | GROUP
  final String text;
  final DateTime date;

  const ZaloUpdate({
    required this.eventName,
    required this.messageId,
    required this.fromId,
    required this.fromName,
    required this.chatId,
    required this.chatType,
    required this.text,
    required this.date,
  });

  bool get isGroup => chatType.toUpperCase() == 'GROUP';

  /// Đọc từ document trong teams/{id}/zaloInbox do Cloudflare Worker ghi.
  static ZaloUpdate? fromInboxDoc(String id, Map<String, dynamic> d) {
    final chatId = d['chatId']?.toString() ?? '';
    if (chatId.isEmpty) return null;
    final rawDate = d['date'];
    DateTime date;
    if (rawDate is DateTime) {
      date = rawDate;
    } else if (rawDate != null && rawDate.runtimeType.toString() == 'Timestamp') {
      date = (rawDate as dynamic).toDate() as DateTime;
    } else {
      date = DateTime.now();
    }
    return ZaloUpdate(
      eventName: d['eventName']?.toString() ?? '',
      messageId: d['messageId']?.toString() ?? id,
      fromId: d['fromId']?.toString() ?? '',
      fromName: d['fromName']?.toString() ?? '',
      chatId: chatId,
      chatType: d['chatType']?.toString() ?? 'PRIVATE',
      text: d['text']?.toString() ?? '',
      date: date,
    );
  }

  static ZaloUpdate? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final msg = Map<String, dynamic>.from((m['message'] as Map?) ?? m);
    final from = Map<String, dynamic>.from((msg['from'] as Map?) ?? {});
    final chat = Map<String, dynamic>.from((msg['chat'] as Map?) ?? {});
    final dateRaw = msg['date'];
    final date = dateRaw is num
        ? DateTime.fromMillisecondsSinceEpoch(
            dateRaw > 100000000000 ? dateRaw.toInt() : dateRaw.toInt() * 1000)
        : DateTime.now();
    final chatId = chat['id']?.toString() ?? '';
    if (chatId.isEmpty) return null;
    return ZaloUpdate(
      eventName: m['event_name']?.toString() ?? '',
      messageId: msg['message_id']?.toString() ?? '',
      fromId: from['id']?.toString() ?? '',
      fromName: from['display_name']?.toString() ?? '',
      chatId: chatId,
      chatType: chat['chat_type']?.toString() ?? 'PRIVATE',
      text: (msg['text'] ?? msg['caption'] ?? '').toString(),
      date: date,
    );
  }
}

class ZaloBotException implements Exception {
  final String message;
  final int? code;
  ZaloBotException(this.message, [this.code]);
  @override
  String toString() => 'Zalo Bot: $message${code == null ? '' : ' ($code)'}';
}

/// Client tối giản cho Zalo Bot API (https://bot-api.zaloplatforms.com).
///
/// Trên web, Zalo không bật CORS nên phải đi qua Cloudflare Worker
/// ([proxyUrl] = URL worker đã có /teamId, [proxySecret] = ZALO_SECRET).
class ZaloBotService {
  ZaloBotService(
    this.token, {
    this.proxyUrl,
    this.proxySecret,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Tạo client theo cấu hình nhóm. Web → dùng proxy nếu đã có URL worker.
  factory ZaloBotService.forTeam(
    TeamSettings s,
    String teamId, {
    String? workerUrl,
    String? secret,
  }) {
    final url = normalizeWorkerUrl(
        (workerUrl ?? '').isNotEmpty ? workerUrl! : s.zaloWebhookUrl, teamId);
    final sec = (secret ?? '').isNotEmpty ? secret! : s.zaloWebhookSecret;
    final useProxy = kIsWeb && url.isNotEmpty;
    return ZaloBotService(
      s.zaloBotToken,
      proxyUrl: useProxy ? url : null,
      proxySecret: useProxy ? sec : null,
    );
  }

  /// Chuẩn hoá URL worker về dạng `https://host/teamId` (bỏ dấu / thừa).
  static String normalizeWorkerUrl(String url, String teamId) {
    var u = url.trim();
    if (u.isEmpty) return '';
    if (!u.startsWith('http')) u = 'https://$u';
    u = u.replaceAll(RegExp(r'/+$'), '');
    if (!u.endsWith('/$teamId')) u = '$u/$teamId';
    return u;
  }

  final String token;
  final String? proxyUrl;
  final String? proxySecret;
  final http.Client _client;

  bool get viaProxy => proxyUrl != null && proxyUrl!.isNotEmpty;

  Future<Map<String, dynamic>> _post(String method, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 20)}) async {
    if (token.isEmpty) throw ZaloBotException('Chưa có Bot Token');
    if (kIsWeb && !viaProxy) {
      throw ZaloBotException(
          'Trình duyệt không gọi trực tiếp được Zalo. Điền URL Worker + secret ở mục Webhook, '
          'hoặc dùng app trên điện thoại.');
    }
    final http.Response res;
    try {
      if (viaProxy) {
        // Dùng query ?zalo=<method> (không thêm đoạn đường dẫn) để chạy được
        // trên cả Cloudflare Worker lẫn Vercel Function.
        res = await _client
            .post(Uri.parse('$proxyUrl?zalo=$method'),
                headers: {
                  'Content-Type': 'application/json',
                  'X-Bot-Api-Secret-Token': proxySecret ?? '',
                },
                body: jsonEncode({'token': token, 'params': body}))
            .timeout(timeout);
      } else {
        res = await _client
            .post(Uri.parse('https://bot-api.zaloplatforms.com/bot$token/$method'),
                headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
            .timeout(timeout);
      }
    } catch (e) {
      throw ZaloBotException('Không kết nối được (${e.runtimeType})');
    }
    final Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {
      throw ZaloBotException('Phản hồi không hợp lệ (HTTP ${res.statusCode})');
    }
    if (json['ok'] != true) {
      final code = (json['error_code'] as num?)?.toInt() ?? res.statusCode;
      // 408 = long polling hết giờ mà không có tin mới: không phải lỗi.
      if (code == 408 && method == 'getUpdates') return {'ok': true, 'result': []};
      throw ZaloBotException(
          (json['description'] ?? json['error'] ?? 'Lỗi').toString(), code);
    }
    return json;
  }

  Future<ZaloBotInfo> getMe() async {
    final json = await _post('getMe', {});
    final r = Map<String, dynamic>.from(json['result'] as Map);
    return ZaloBotInfo(
      id: r['id']?.toString() ?? '',
      displayName: r['display_name']?.toString() ?? r['account_name']?.toString() ?? '',
      canJoinGroups: r['can_join_groups'] == true,
    );
  }

  /// Gửi tin nhắn văn bản tới người dùng hoặc nhóm. Trả về message_id.
  Future<String> sendMessage(String chatId, String text) async {
    final clipped = text.length > 2000 ? text.substring(0, 2000) : text;
    final json = await _post('sendMessage', {'chat_id': chatId, 'text': clipped});
    final r = (json['result'] as Map?) ?? {};
    return r['message_id']?.toString() ?? '';
  }

  /// Đăng ký webhook. Zalo tự gửi request kiểm tra và trả kết quả trong
  /// `verification`. Trả về mô tả ngắn kết quả xác minh.
  Future<String> setWebhook(String url, String secretToken) async {
    final json = await _post('setWebhook', {'url': url, 'secret_token': secretToken});
    final r = (json['result'] as Map?) ?? {};
    final v = (r['verification'] as Map?) ?? {};
    if (v.isEmpty) return 'Đã đăng ký webhook';
    final ok = v['ok'] == true;
    return '${ok ? '✅' : '❌'} ${v['outcome'] ?? ''} ${v['hint'] ?? ''}'.trim();
  }

  Future<void> deleteWebhook() async {
    await _post('deleteWebhook', {});
  }

  /// URL webhook hiện tại (rỗng nếu chưa đặt).
  Future<String> getWebhookInfo() async {
    try {
      final json = await _post('getWebhookInfo', {});
      final r = (json['result'] as Map?) ?? {};
      return r['url']?.toString() ?? '';
    } on ZaloBotException catch (e) {
      if (e.code == 404) return '';
      rethrow;
    }
  }

  /// Long polling: đợi tối đa [timeoutSeconds] giây để lấy tin mới.
  /// Zalo trả 408 khi không có tin → trả về danh sách rỗng.
  Future<List<ZaloUpdate>> getUpdates({int timeoutSeconds = 10}) async {
    final json = await _post(
      'getUpdates',
      {'timeout': timeoutSeconds},
      timeout: Duration(seconds: timeoutSeconds + 10),
    );
    final result = json['result'];
    final items = result is List ? result : (result == null ? const [] : [result]);
    return items.map(ZaloUpdate.tryParse).whereType<ZaloUpdate>().toList();
  }
}
