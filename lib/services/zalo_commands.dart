import '../utils/text.dart';

/// Lệnh chat với bot (gõ trong nhóm kèm @bot, hoặc nhắn riêng).
/// Phần trả lời tự động khi webhook bật nằm ở webhook/zalo-webhook.js; file này
/// dùng khi app tự hỏi Zalo (getUpdates) và để không tính lệnh thành vote.
class ZaloCommands {
  ZaloCommands._();

  static const appUrl = 'https://duongson-jvb.github.io/pickleball_fund/';

  static const helpText = '🏓 BOT QUỸ PICKLEBALL\n'
      '\n'
      '🗳 VOTE · reply tin vote: 1 = đi · 2 = đi 2 người · 0 = không\n'
      '   "@An 1" vote hộ · "vote" xem buổi đang mở\n'
      '🥤 NƯỚC · "nước" xem mã & giá · "N1 2" ghi · "+1 N1" cộng · "@An N1 2" nhập hộ\n'
      '💰 QUỸ · "quỹ" xem số dư cả nhóm\n'
      '💬 Hỏi gì cứ @bot, em trả lời\n'
      '📱 App: $appUrl';

  // "menu" chỉ tính khi đứng một mình: "menu nước" là xem danh sách nước.
  static final _helpPattern =
      RegExp(r'(^|\s)(help|huong dan|tro giup|lenh|cach dung|hdsd)(\s|$)|^menu$');
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

  static final _voteListPattern = RegExp(
      r'^(vote|ds vote|danh sach vote|list vote|vote nao|lich vote|buoi vote|dang vote|vote dang mo|xem vote|vote di)$');

  /// "@bot vote" → xem các buổi đang mở vote.
  static bool isVoteList(String text, {String botName = ''}) {
    var t = text;
    if (botName.isNotEmpty) t = normalizeVi(t).replaceAll(normalizeVi(botName), ' ');
    return _voteListPattern.hasMatch(_clean(t));
  }

  /// Có phải là lệnh (không nên tính thành vote / tin chờ) không.
  static bool isCommand(String text) => isHelp(text);
}
