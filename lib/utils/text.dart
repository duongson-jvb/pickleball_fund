import 'dart:math';

/// Chuỗi ngẫu nhiên chữ + số (dùng làm secret webhook). An toàn trên web.
String randomSecret({int length = 24, String prefix = 'pb-'}) {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  Random rng;
  try {
    rng = Random.secure();
  } catch (_) {
    rng = Random();
  }
  final sb = StringBuffer(prefix);
  for (var i = 0; i < length; i++) {
    sb.write(chars[rng.nextInt(chars.length)]);
  }
  return sb.toString();
}

/// Bỏ dấu tiếng Việt, viết thường, gộp khoảng trắng – dùng để khớp tên.
String normalizeVi(String s) {
  const withDiacritics =
      'àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ';
  const without =
      'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
  var out = s.toLowerCase();
  for (var i = 0; i < withDiacritics.length; i++) {
    out = out.replaceAll(withDiacritics[i], without[i]);
  }
  // Chuỗi dạng tổ hợp (NFD, hay gặp trên Mac/iPhone): "ư" = u + U+031B,
  // dấu thanh là ký tự rời U+0300–U+036F → bỏ hết các dấu kết hợp.
  out = out.replaceAll(RegExp(r'[\u0300-\u036f]'), '');
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// [haystack] có chứa [needle] như một cụm từ TRỌN VẸN không (cả hai đã
/// chuẩn hoá bằng [normalizeVi]). Dùng để khớp tên người chơi: "An" không
/// được khớp vào "Hoàng", "Lan" hay "bạn".
bool containsWholeWord(String haystack, String needle) {
  if (needle.isEmpty || haystack.isEmpty) return false;
  return RegExp('(^|[^a-z0-9])${RegExp.escape(needle)}([^a-z0-9]|\$)')
      .hasMatch(haystack);
}
