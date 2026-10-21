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
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}
