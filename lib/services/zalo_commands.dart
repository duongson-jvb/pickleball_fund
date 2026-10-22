import '../utils/text.dart';

/// Lệnh chat với bot (gõ trong nhóm kèm @bot, hoặc nhắn riêng).
/// Phần trả lời tự động khi webhook bật nằm ở worker/src/index.js; file này
/// dùng khi app tự hỏi Zalo (getUpdates) và để không tính lệnh thành vote.
class ZaloCommands {
  ZaloCommands._();

  static const appUrl = 'https://duongson-jvb.github.io/pickleball_fund/';

  static const helpText = '🏓 Bot Quỹ Pickleball\n'
      '• Vote đi chơi: Reply tin vote của bot → 1 = đi, 0 = không\n'
      '• Đổi ý: reply lại là xong\n'
      '• Người mới cứ reply 1, bot tự thêm tên vào danh sách\n'
      '• Xem quỹ, tiền sân, tiền nước: $appUrl\n'
      '• Gõ @bot help để xem lại tin này';

  static final _helpPattern =
      RegExp(r'(^|\s)(help|huong dan|tro giup|menu|lenh|cach dung|hdsd)(\s|$)');

  /// "@Bot PickleBall JVB help", "hướng dẫn", "?" → true.
  static bool isHelp(String text) {
    final stripped = normalizeVi(text).replaceAll(RegExp(r'@\S+'), ' ');
    final t = stripped.replaceAll(RegExp(r'[?!.,]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (_helpPattern.hasMatch(t)) return true;
    return stripped.trim() == '?';
  }

  /// Có phải là lệnh (không nên tính thành vote / tin chờ) không.
  static bool isCommand(String text) => isHelp(text);
}
