import '../models/models.dart';
import '../utils/text.dart';

/// Một thay đổi số lượng nước: đặt bằng [qty] hoặc cộng/trừ [qty].
class DrinkChange {
  final String drinkTypeId;
  final int qty;
  final bool relative; // true = cộng/trừ, false = đặt bằng
  const DrinkChange(this.drinkTypeId, this.qty, {this.relative = false});

  int apply(int current) => relative ? (current + qty).clamp(0, 999) : qty.clamp(0, 999);
}

/// Kết quả phân tích lệnh nước.
class DrinkCommand {
  final List<DrinkChange> changes;
  final String? error; // lệnh có vẻ về nước nhưng không hiểu
  const DrinkCommand(this.changes, {this.error});
  bool get isValid => error == null && changes.isNotEmpty;
}

/// Hiểu lệnh ghi nước trong chat Zalo, ví dụ:
///   "nước 2"             → 2 (khi chỉ có 1 loại nước)
///   "nước revive 2"      → Revive = 2
///   "nước 2 revive 1 suối" / "revive 2, suối 1" → nhiều loại
///   "+1 revive" / "revive +1" → cộng thêm 1
///   "nước 0"             → xoá
class ZaloDrinks {
  ZaloDrinks._();

  static final _nuocWord = RegExp(r'(^|\s)(nuoc|drink)(\s|$)');

  /// Có phải tin về nước không (để không nhầm thành vote).
  static bool looksLikeDrink(String text, List<DrinkType> types, {String botName = ''}) {
    final t = _clean(text, botName);
    if (_nuocWord.hasMatch(t)) return true;
    for (final d in types) {
      for (final n in aliases(d)) {
        if (RegExp('(^|\\s)${RegExp.escape(n)}(\\s|,|\$)').hasMatch(t)) {
          // Có tên nước kèm số → là lệnh nước.
          if (RegExp(r'[+-]?\d').hasMatch(t)) return true;
        }
      }
    }
    return false;
  }

  static DrinkCommand parse(String text, List<DrinkType> types, {String botName = ''}) {
    var t = _clean(text, botName);
    final active = types.where((d) => d.active).toList();
    if (active.isEmpty) return const DrinkCommand([], error: 'Nhóm chưa có loại nước nào');

    final changes = <DrinkChange>[];
    // Khớp từng loại nước theo các tên gọi (tên đầy đủ và tên bỏ chữ "nước"),
    // ưu tiên tên dài trước để "trà đá" không bị nhầm với "trà".
    final pairs = <(DrinkType, String)>[
      for (final d in active)
        for (final a in aliases(d)) (d, a),
    ]..sort((x, y) => y.$2.length.compareTo(x.$2.length));
    final done = <String>{};
    var padded = ' $t ';
    for (final (d, alias) in pairs) {
      if (done.contains(d.id)) continue;
      final n = RegExp.escape(alias);
      if (n.isEmpty) continue;
      // số trước tên: "2 revive", "+1 revive";  số sau tên: "revive 2", "revive +1"
      final re = RegExp('(?:([+-])?(\\d+)\\s*)?[\\s,]$n(?:\\s*([+-])?(\\d+))?(?=[\\s,])');
      final m = re.firstMatch(padded);
      if (m == null) continue;
      final signBefore = m.group(1), numBefore = m.group(2);
      final signAfter = m.group(3), numAfter = m.group(4);
      final num = numAfter ?? numBefore;
      if (num == null) continue;
      final sign = numAfter != null ? signAfter : signBefore;
      final q = int.parse(num) * (sign == '-' ? -1 : 1);
      changes.add(DrinkChange(d.id, q, relative: sign != null));
      done.add(d.id);
      padded = padded.replaceRange(m.start, m.end, ' ');
    }
    if (changes.isNotEmpty) return DrinkCommand(changes);
    t = padded.trim();

    // Chỉ có số, không có tên: "nước 2", "+1 nước"
    final m = RegExp(r'([+-])?(\d+)').firstMatch(t);
    if (m == null) return const DrinkCommand([], error: 'Chưa có số lượng');
    if (active.length != 1) {
      return DrinkCommand([],
          error: 'Nhóm có ${active.length} loại nước, ghi rõ tên: '
              '${active.map((d) => '"${d.name} <số>"').join(', ')}');
    }
    final sign = m.group(1);
    final q = int.parse(m.group(2)!) * (sign == '-' ? -1 : 1);
    return DrinkCommand([DrinkChange(active.single.id, q, relative: sign != null)]);
  }

  /// Chọn buổi chơi để ghi nước: buổi gần [at] nhất mà người đó có tham gia
  /// (trong khoảng 36 giờ trước → 6 giờ sau giờ bắt đầu).
  static Session? pickSession(List<Session> sessions, String playerId, DateTime at) {
    Session? best;
    Duration? bestGap;
    for (final s in sessions) {
      if (!s.playerIds.contains(playerId) && !(s.votes[playerId] == true)) continue;
      final gap = at.difference(s.date);
      if (gap > const Duration(hours: 36) || gap < const Duration(hours: -6)) continue;
      final abs = gap.abs();
      if (bestGap == null || abs < bestGap) {
        best = s;
        bestGap = abs;
      }
    }
    return best;
  }

  /// Áp dụng thay đổi vào bản đồ nước của một người. Trả về bản mới.
  static Map<String, Map<String, int>> applyChanges(
      Map<String, Map<String, int>> drinks, String playerId, List<DrinkChange> changes) {
    final out = {for (final e in drinks.entries) e.key: {...e.value}};
    final mine = out.putIfAbsent(playerId, () => {});
    for (final c in changes) {
      final v = c.apply(mine[c.drinkTypeId] ?? 0);
      if (v <= 0) {
        mine.remove(c.drinkTypeId);
      } else {
        mine[c.drinkTypeId] = v;
      }
    }
    if (mine.isEmpty) out.remove(playerId);
    return out;
  }

  /// Các tên gọi (đã bỏ dấu) của một loại nước: tên đầy đủ và tên bỏ chữ "nước".
  /// "Nước suối" → ["nuoc suoi", "suoi"]; "Revive" → ["revive"].
  static List<String> aliases(DrinkType d) {
    final full = normalizeVi(d.name);
    final out = <String>[];
    if (full.isNotEmpty) out.add(full);
    final short = full.replaceFirst(RegExp(r'^nuoc\s+'), '').trim();
    if (short.isNotEmpty && short != full) out.add(short);
    return out;
  }

  static String _clean(String text, String botName) {
    var t = normalizeVi(text);
    if (botName.isNotEmpty) t = t.replaceAll(normalizeVi(botName), ' ');
    t = t.replaceAll(RegExp(r'@\S+'), ' ').replaceAll(RegExp(r'[.!?:;]+'), ' ');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
