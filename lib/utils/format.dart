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

/// Đọc số tiền người dùng nhập, chấp nhận "50.000", "50,000", "50k", "1tr".
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
  s = s.replaceAll('.', '').replaceAll(',', '.');
  final v = double.tryParse(s) ?? 0;
  return (v * multiplier).round();
}
