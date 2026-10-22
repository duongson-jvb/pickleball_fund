import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/team_store.dart';
import 'common.dart';

/// Yêu cầu quyền quản trị trước khi sửa dữ liệu.
/// Trả về true nếu đang là quản trị (hoặc vừa mở khoá thành công).
Future<bool> requireAdmin(BuildContext context) async {
  final store = TeamScope.of(context);
  if (store.isAdmin) return true;
  if (!store.settings.hasAdmin) {
    final set = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Chưa có mã bảo mật'),
        content: const Text(
          'Nhóm chưa đặt mã bảo mật quản trị nên chưa sửa được dữ liệu. '
          'Đặt mã ngay? Người giữ mã sẽ là người được sửa quỹ.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Để sau')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Đặt mã')),
        ],
      ),
    );
    if (set != true || !context.mounted) return false;
    return setupAdminPin(context);
  }
  if (!context.mounted) return false;
  return unlockAdmin(context);
}

/// Hộp thoại nhập mã để mở khoá quản trị.
Future<bool> unlockAdmin(BuildContext context) async {
  final store = TeamScope.of(context);
  final ctrl = TextEditingController();
  String? error;
  var busy = false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.lock_outline),
          SizedBox(width: 8),
          Text('Mã bảo mật quản trị'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Chỉ quản trị viên mới sửa được quỹ, buổi chơi, chi phí, cài đặt. '
                'Vote thì không cần mã.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(labelText: 'Mã bảo mật', errorText: error),
              onSubmitted: (_) => _tryUnlock(ctx, store, ctrl.text, setState, (e) => error = e, (b) => busy = b),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(
            onPressed: busy
                ? null
                : () => _tryUnlock(ctx, store, ctrl.text, setState, (e) => error = e, (b) => busy = b),
            child: busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Mở khoá'),
          ),
        ],
      ),
    ),
  );
  return ok == true;
}

Future<void> _tryUnlock(
  BuildContext ctx,
  TeamStore store,
  String pin,
  void Function(void Function()) setState,
  void Function(String?) setError,
  void Function(bool) setBusy,
) async {
  setState(() {
    setBusy(true);
    setError(null);
  });
  try {
    final uid = await store.auth.unlock(store.repo.teamId, pin.trim());
    if (uid != store.settings.adminUid) {
      // Có tài khoản nhưng không trùng uid đã lưu (hiếm, dữ liệu lệch) → tự sửa lại.
      await store.repo.claimAdmin(uid);
    }
    if (ctx.mounted) Navigator.pop(ctx, true);
  } catch (e) {
    setState(() {
      setBusy(false);
      setError(AuthService.describe(e));
    });
  }
}

/// Đặt mã bảo mật lần đầu cho nhóm (tạo tài khoản quản trị).
Future<bool> setupAdminPin(BuildContext context) async {
  final store = TeamScope.of(context);
  final p1 = TextEditingController();
  final p2 = TextEditingController();
  String? error;
  var busy = false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Đặt mã bảo mật quản trị'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Ít nhất 6 ký tự. Chia sẻ mã này chỉ cho người được phép sửa quỹ.'),
            const SizedBox(height: 12),
            TextField(
              controller: p1,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Mã bảo mật'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: p2,
              obscureText: true,
              decoration: InputDecoration(labelText: 'Nhập lại', errorText: error),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    if (p1.text.trim().length < 6) {
                      setState(() => error = 'Cần ít nhất 6 ký tự');
                      return;
                    }
                    if (p1.text != p2.text) {
                      setState(() => error = 'Hai lần nhập không khớp');
                      return;
                    }
                    setState(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      final uid = await store.auth.createAdmin(store.repo.teamId, p1.text.trim());
                      await store.repo.claimAdmin(uid);
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      setState(() {
                        busy = false;
                        error = AuthService.describe(e);
                      });
                    }
                  },
            child: busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Lưu mã'),
          ),
        ],
      ),
    ),
  );
  if (ok == true && context.mounted) showSnack(context, 'Đã đặt mã bảo mật. Bạn đang ở chế độ quản trị.');
  return ok == true;
}

/// Đổi mã bảo mật (đang là quản trị).
Future<void> changeAdminPin(BuildContext context) async {
  final store = TeamScope.of(context);
  final cur = TextEditingController();
  final p1 = TextEditingController();
  final p2 = TextEditingController();
  String? error;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Đổi mã bảo mật'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: cur, obscureText: true, autofocus: true,
                decoration: const InputDecoration(labelText: 'Mã hiện tại')),
            const SizedBox(height: 8),
            TextField(controller: p1, obscureText: true,
                decoration: const InputDecoration(labelText: 'Mã mới (≥ 6 ký tự)')),
            const SizedBox(height: 8),
            TextField(controller: p2, obscureText: true,
                decoration: InputDecoration(labelText: 'Nhập lại mã mới', errorText: error)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Huỷ')),
          FilledButton(
            onPressed: () async {
              if (p1.text != p2.text) {
                setState(() => error = 'Hai lần nhập không khớp');
                return;
              }
              try {
                await store.auth.changePin(store.repo.teamId, cur.text.trim(), p1.text.trim());
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) showSnack(context, 'Đã đổi mã bảo mật');
              } catch (e) {
                setState(() => error = AuthService.describe(e));
              }
            },
            child: const Text('Đổi'),
          ),
        ],
      ),
    ),
  );
}

/// Nút ổ khoá cho AppBar: hiện trạng thái, bấm để mở/khoá quản trị.
class AdminLockButton extends StatelessWidget {
  const AdminLockButton({super.key});

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final admin = store.isAdmin;
    return IconButton(
      tooltip: admin ? 'Đang ở chế độ quản trị · bấm để khoá' : 'Mở khoá quản trị',
      icon: Icon(admin ? Icons.lock_open : Icons.lock_outline,
          color: admin ? Colors.green.shade700 : null),
      onPressed: () async {
        if (admin) {
          if (await confirm(context, 'Khoá chế độ quản trị?',
              message: 'Vẫn xem và vote được, nhưng không sửa được dữ liệu cho tới khi nhập lại mã.',
              okLabel: 'Khoá', danger: false)) {
            await store.auth.lock();
          }
        } else {
          await requireAdmin(context);
        }
      },
    );
  }
}
