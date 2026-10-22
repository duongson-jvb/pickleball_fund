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

/// Một phần việc ghi nước cho một người: [player] null = chính người gửi
/// (hoặc không tìm thấy người được @ – xem [nameText]).
class DrinkAssignment {
  final Player? player;
  final String nameText; // tên gõ trong tin (rỗng = tự mình)
  final DrinkCommand command;
  const DrinkAssignment(this.player, this.nameText, this.command);
  bool get isSelf => nameText.isEmpty;
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

  /// Có phải tin ghi nước không (để không nhầm thành vote). Tin ghi nước luôn
  /// có chữ số; "nước" không kèm số là yêu cầu xem danh sách (xử lý riêng).
  static bool looksLikeDrink(String text, List<DrinkType> types, {String botName = ''}) {
    final t = _clean(text, botName);
    if (!RegExp(r'\d').hasMatch(t)) return false;
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

  /// Tách tin có @mention người chơi thành từng phần việc:
  ///   "N1 2 @An N2 1 @Nguyễn Văn Bình revive 2, suối 1"
  /// → [tự mình: N1 2], [An: N2 1], [Nguyễn Văn Bình: revive 2, suối 1].
  /// Tên người: khớp dài nhất với danh sách (không dấu, không phân biệt hoa thường);
  /// không khớp thì lấy các từ đứng trước số/tên nước làm tên để báo lỗi.
  static List<DrinkAssignment> parseMulti(
    String text,
    List<DrinkType> types,
    List<Player> players, {
    String botName = '',
  }) {
    var t = normalizeVi(text);
    if (botName.isNotEmpty) t = t.replaceAll(normalizeVi(botName), ' ');
    t = t.replaceAll(RegExp(r'[.!?:;]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final parts = t.split('@');
    final out = <DrinkAssignment>[];
    final head = parts.first.trim();
    if (head.isNotEmpty && RegExp(r'\d').hasMatch(head)) {
      out.add(DrinkAssignment(null, '', parse(head, types)));
    }
    for (final raw in parts.skip(1)) {
      final seg = raw.trim();
      if (seg.isEmpty) continue;
      Player? best;
      var bestLen = 0;
      for (final p in players) {
        final n = normalizeVi(p.name);
        if (n.isEmpty) continue;
        if ((seg == n || seg.startsWith('$n ')) && n.length > bestLen) {
          best = p;
          bestLen = n.length;
        }
      }
      String nameText;
      String rest;
      if (best != null) {
        nameText = best.name;
        rest = seg.substring(bestLen).trim();
      } else {
        final tokens = seg.split(' ');
        var i = 0;
        while (i < tokens.length &&
            !RegExp(r'\d').hasMatch(tokens[i]) &&
            !_startsWithAlias(tokens.skip(i).join(' '), types)) {
          i++;
        }
        nameText = tokens.take(i).join(' ');
        rest = tokens.skip(i).join(' ');
        best = _matchName(nameText, players);
        // "@bot ..." (tên bot chưa lưu trong cài đặt) → lệnh cho chính người gửi.
        if (best == null && (nameText == 'bot' || nameText.startsWith('bot '))) {
          if (rest.isNotEmpty) out.add(DrinkAssignment(null, '', parse(rest, types)));
          continue;
        }
      }
      out.add(DrinkAssignment(best, nameText, parse(rest, types)));
    }
    return out;
  }

  static bool _startsWithAlias(String s, List<DrinkType> types) {
    for (final d in types) {
      for (final a in aliases(d)) {
        if (s == a || s.startsWith('$a ')) return true;
      }
    }
    return false;
  }

  /// Khớp tên người chơi: chính xác, hoặc khớp một phần nhưng duy nhất.
  static Player? _matchName(String nameText, List<Player> players) {
    final n = normalizeVi(nameText);
    if (n.isEmpty) return null;
    final exact = players.where((p) => normalizeVi(p.name) == n).toList();
    if (exact.length == 1) return exact.first;
    final partial = players.where((p) {
      final pn = normalizeVi(p.name);
      return pn.isNotEmpty && (pn.contains(n) || n.contains(pn));
    }).toList();
    return partial.length == 1 ? partial.first : null;
  }

  /// Các tên gọi (đã bỏ dấu) của một loại nước: tên đầy đủ, tên bỏ chữ "nước",
  /// và mã ngắn ("n1", "#1"). "Nước suối" (N2) → ["nuoc suoi", "suoi", "n2", "#2"].
  static List<String> aliases(DrinkType d) {
    final full = normalizeVi(d.name);
    final out = <String>[];
    if (full.isNotEmpty) out.add(full);
    final short = full.replaceFirst(RegExp(r'^nuoc\s+'), '').trim();
    if (short.isNotEmpty && short != full) out.add(short);
    if (d.code > 0) out.addAll(['n${d.code}', '#${d.code}']);
    return out;
  }

  static final _listWords = RegExp(
      r'^(nuoc|drink|menu nuoc|danh sach nuoc|nuoc menu|gia nuoc|bang gia|bang gia nuoc|list nuoc|ds nuoc)$');

  /// "@bot nước" (không kèm số) → yêu cầu xem danh sách nước.
  static bool isListRequest(String text, {String botName = ''}) {
    final t = _clean(text, botName).replaceAll('?', '').trim();
    return _listWords.hasMatch(t);
  }

  /// Danh sách nước kèm mã và giá, gửi lên Zalo.
  static String listText(List<DrinkType> types, {DateTime? on}) {
    final active = types.where((d) => d.active).toList()
      ..sort((a, b) => (a.code == 0 ? 1 << 20 : a.code).compareTo(b.code == 0 ? 1 << 20 : b.code));
    if (active.isEmpty) return '🥤 Nhóm chưa có loại nước nào. Quản lý thêm trong app → Cài đặt → Loại nước & giá.';
    final day = on ?? DateTime.now();
    final sb = StringBuffer('🥤 DANH SÁCH NƯỚC\n');
    for (final d in active) {
      final code = d.codeLabel.isEmpty ? '•' : d.codeLabel;
      sb.writeln('$code · ${d.name} · ${_vnd(d.priceOn(day))}');
    }
    sb.writeln('Ghi nước: "N1 2" hoặc "${active.first.name} 2"; nhiều loại: "N1 2, N2 1"; cộng thêm: "+1 N1"');
    return sb.toString().trimRight();
  }

  static String _vnd(int v) {
    final s = v.toString();
    final sb = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) sb.write('.');
      sb.write(s[i]);
    }
    sb.write('đ');
    return sb.toString();
  }

  static String _clean(String text, String botName) {
    var t = normalizeVi(text);
    if (botName.isNotEmpty) t = t.replaceAll(normalizeVi(botName), ' ');
    t = t.replaceAll(RegExp(r'@\S*'), ' ').replaceAll(RegExp(r'[.!?:;]+'), ' ');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
