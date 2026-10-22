import 'package:intl/intl.dart';

final _vnd = NumberFormat.decimalPattern('vi_VN');
final _dateFmt = DateFormat('dd/MM/yyyy');
final _dateTimeFmt = DateFormat('HH:mm dd/MM/yyyy');
final _weekdayFmt = DateFormat('EEEE dd/MM', 'vi_VN');

/// 50000 -> "50.000đ"
String vnd(int amount) => '${_vnd.format(amount)}đ';

/// -50000 -> "-50.000đ", 50000 -> "+50.000đ"
String vndSigned(int amount) => amount >= 0 ? '+${vnd(amount)}' : vnd(amount);

String fmtDate(DateTime d) => _dateFmt.format(d);
String fmtDateTime(DateTime d) => _dateTimeFmt.format(d);
String fmtWeekday(DateTime d) {
  final s = _weekdayFmt.format(d);
  return s.isEmpty ? fmtDate(d) : s[0].toUpperCase() + s.substring(1);
}

/// Đọc số tiền người dùng nhập, chấp nhận "50.000", "50,000", "50k", "1tr",
/// "5.5k" (= 5.500đ), "1,5tr" (= 1.500.000đ).
///
/// Dấu chấm / phẩy cuối cùng được hiểu là phân cách NGHÌN khi sau nó có đúng
/// 3 chữ số ("50.000"), và là dấu THẬP PHÂN khi sau nó có 1-2 chữ số ("5.5k").
int parseAmount(String input) {
  var s = input.trim().toLowerCase().replaceAll(' ', '');
  if (s.isEmpty) return 0;
  var multiplier = 1;
  if (s.endsWith('tr') || s.endsWith('m')) {
    multiplier = 1000000;
    s = s.replaceAll(RegExp(r'(tr|m)$'), '');
  } else if (s.endsWith('k')) {
    multiplier = 1000;
    s = s.substring(0, s.length - 1);
  }
  final sep = s.lastIndexOf(RegExp(r'[.,]'));
  if (sep >= 0) {
    final tail = s.substring(sep + 1);
    final head = s.substring(0, sep).replaceAll(RegExp(r'[.,]'), '');
    s = RegExp(r'^\d{1,2}$').hasMatch(tail) ? '$head.$tail' : '$head$tail';
  }
  final v = double.tryParse(s) ?? 0;
  return (v * multiplier).round();
}
