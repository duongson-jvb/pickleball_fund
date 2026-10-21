import 'dart:convert';

import 'package:http/http.dart' as http;

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
class ZaloBotService {
  ZaloBotService(this.token, {http.Client? client})
      : _client = client ?? http.Client();

  final String token;
  final http.Client _client;

  Uri _uri(String method) =>
      Uri.parse('https://bot-api.zaloplatforms.com/bot$token/$method');

  Future<Map<String, dynamic>> _post(String method, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final res = await _client
        .post(_uri(method),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(timeout);
    final Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {
      throw ZaloBotException('Phản hồi không hợp lệ (HTTP ${res.statusCode})');
    }
    if (json['ok'] != true) {
      final code = (json['error_code'] as num?)?.toInt();
      // 408 = long polling hết giờ mà không có tin mới: không phải lỗi.
      if (code == 408 && method == 'getUpdates') return {'ok': true, 'result': []};
      throw ZaloBotException(json['description']?.toString() ?? 'Lỗi', code);
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
