import '../utils/text.dart';

/// Lệnh chat với bot (gõ trong nhóm kèm @bot, hoặc nhắn riêng).
/// Phần trả lời tự động khi webhook bật nằm ở webhook/zalo-webhook.js; file này
/// dùng khi app tự hỏi Zalo (getUpdates) và để không tính lệnh thành vote.
class ZaloCommands {
  ZaloCommands._();

  static const appUrl = 'https://duongson-jvb.github.io/pickleball_fund/';

  static const helpText = '🏓 Bot Quỹ Pickleball\n'
      '• Vote: reply tin vote → 1 = đi, 0 = không (đổi ý reply lại)\n'
      '• Nước: "nước" xem mã & giá · "N1 2" ghi · "+1 N1" cộng · "@An N1 2" nhập hộ\n'
      '• Quỹ: "quỹ" xem số dư cả nhóm\n'
      '• Hỏi gì cứ @bot, em trả lời\n'
      '• App: $appUrl';

  static final _helpPattern =
      RegExp(r'(^|\s)(help|huong dan|tro giup|menu|lenh|cach dung|hdsd)(\s|$)');
  static final _fundPattern =
      RegExp(r'^(quy|so du|bao quy|tien quy|quy nhom|xem quy|quy team)$');

  static String _clean(String text) {
    final stripped = normalizeVi(text).replaceAll(RegExp(r'@\S*'), ' ');
    return stripped.replaceAll(RegExp(r'[?!.,:;]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// "@Bot PickleBall JVB help", "hướng dẫn", "?" → true.
  static bool isHelp(String text) {
    final t = _clean(text);
    if (_helpPattern.hasMatch(t)) return true;
    return normalizeVi(text).replaceAll(RegExp(r'@\S*'), ' ').trim() == '?';
  }

  /// "@bot quỹ", "quy", "số dư" → xem bảng số dư cả nhóm.
  static bool isFund(String text, {String botName = ''}) {
    var t = text;
    if (botName.isNotEmpty) t = normalizeVi(t).replaceAll(normalizeVi(botName), ' ');
    return _fundPattern.hasMatch(_clean(t));
  }

  /// Có phải là lệnh (không nên tính thành vote / tin chờ) không.
  static bool isCommand(String text) => isHelp(text);
}
