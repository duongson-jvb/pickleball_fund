import 'dart:convert';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Chọn ảnh từ thư viện / camera, nén nhỏ và trả về chuỗi base64
/// để lưu thẳng vào Firestore (không cần Firebase Storage).
class ImageUtil {
  ImageUtil._();

  static final _picker = ImagePicker();

  static Future<String?> pickAsBase64({
    ImageSource source = ImageSource.gallery,
    double maxWidth = 1000,
    int quality = 60,
  }) async {
    final file = await _picker.pickImage(
      source: source,
      maxWidth: maxWidth,
      maxHeight: maxWidth,
      imageQuality: quality,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    // Firestore giới hạn 1MB / document, giữ ảnh dưới ~700KB.
    if (bytes.lengthInBytes > 700 * 1024) {
      final smaller = await _picker.pickImage(
        source: source,
        maxWidth: 600,
        maxHeight: 600,
        imageQuality: 40,
      );
      if (smaller == null) return null;
      return base64Encode(await smaller.readAsBytes());
    }
    return base64Encode(bytes);
  }

  static Uint8List decode(String b64) => base64Decode(b64);
}
