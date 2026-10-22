import 'package:firebase_auth/firebase_auth.dart';

/// Đăng nhập Firebase:
/// - Mọi người: đăng nhập ẩn danh để xem và vote (Firestore rules yêu cầu có auth).
/// - Quản trị viên: đăng nhập bằng tài khoản tổng hợp của nhóm
///   (email theo mã nhóm + mã bảo mật làm mật khẩu). uid được lưu vào
///   teams/{teamId}.adminUid và rules chỉ cho uid đó sửa dữ liệu.
class AuthService {
  AuthService({FirebaseAuth? auth}) : _authOrNull = auth ?? FirebaseAuth.instance;

  /// Không dùng Firebase Auth (test / Firestore giả lập): coi như luôn là quản trị.
  AuthService.none() : _authOrNull = null;

  final FirebaseAuth? _authOrNull;
  FirebaseAuth get _auth =>
      _authOrNull ?? (throw StateError('Firebase Auth chưa được cấu hình'));
  bool get isConfigured => _authOrNull != null;

  Stream<User?> get changes => _authOrNull?.authStateChanges() ?? const Stream.empty();
  User? get currentUser => _authOrNull?.currentUser;
  String? get uid => _authOrNull?.currentUser?.uid;

  /// Email tổng hợp cho tài khoản quản trị của một nhóm.
  static String adminEmail(String teamId) => 'admin-$teamId@team.pickleball.app';

  /// Đảm bảo đã đăng nhập (ẩn danh nếu chưa có gì).
  Future<void> ensureSignedIn() async {
    if (!isConfigured) return;
    if (_auth.currentUser != null) return;
    await _auth.signInAnonymously();
  }

  /// Người dùng hiện tại có phải quản trị viên của nhóm không.
  bool isAdminOf(String adminUid) {
    if (!isConfigured) return true;
    final u = _auth.currentUser;
    return u != null && !u.isAnonymous && adminUid.isNotEmpty && u.uid == adminUid;
  }

  /// Đặt mã bảo mật lần đầu: tạo tài khoản quản trị. Trả về uid.
  Future<String> createAdmin(String teamId, String pin) async {
    _validatePin(pin);
    final cred = await _auth.createUserWithEmailAndPassword(
      email: adminEmail(teamId),
      password: pin,
    );
    return cred.user!.uid;
  }

  /// Mở khoá quản trị bằng mã bảo mật. Trả về uid.
  Future<String> unlock(String teamId, String pin) async {
    final cred = await _auth.signInWithEmailAndPassword(
      email: adminEmail(teamId),
      password: pin,
    );
    return cred.user!.uid;
  }

  /// Khoá lại: về tài khoản ẩn danh (vẫn xem và vote được).
  Future<void> lock() async {
    await _auth.signOut();
    await _auth.signInAnonymously();
  }

  /// Đổi mã bảo mật (phải đang là quản trị).
  Future<void> changePin(String teamId, String currentPin, String newPin) async {
    _validatePin(newPin);
    final u = _auth.currentUser;
    if (u == null || u.isAnonymous) throw StateError('Chưa mở khoá quản trị');
    await u.reauthenticateWithCredential(
      EmailAuthProvider.credential(email: adminEmail(teamId), password: currentPin),
    );
    await u.updatePassword(newPin);
  }

  void _validatePin(String pin) {
    if (pin.trim().length < 6) {
      throw ArgumentError('Mã bảo mật cần ít nhất 6 ký tự');
    }
  }

  /// Chuyển lỗi Firebase Auth thành câu tiếng Việt ngắn.
  static String describe(Object e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'wrong-password':
        case 'invalid-credential':
        case 'INVALID_LOGIN_CREDENTIALS':
          return 'Sai mã bảo mật';
        case 'user-not-found':
          return 'Nhóm chưa đặt mã bảo mật';
        case 'too-many-requests':
          return 'Thử sai quá nhiều lần, đợi một lúc rồi thử lại';
        case 'email-already-in-use':
          return 'Nhóm này đã có mã bảo mật, hãy dùng "Mở khoá"';
        case 'weak-password':
          return 'Mã bảo mật quá yếu, cần ít nhất 6 ký tự';
        case 'operation-not-allowed':
          return 'Firebase chưa bật đăng nhập Email/Password';
        case 'network-request-failed':
          return 'Không có mạng';
        default:
          return e.message ?? e.code;
      }
    }
    if (e is ArgumentError) return e.message.toString();
    return e.toString();
  }
}
