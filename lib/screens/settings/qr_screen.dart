import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/image_util.dart';
import '../../services/share_service.dart';
import '../../services/team_store.dart';
import '../../widgets/admin_gate.dart';
import '../../widgets/common.dart';

/// Màn hình QR chuyển khoản: xem, đổi ảnh QR, sửa thông tin tài khoản, chia sẻ.
class QrScreen extends StatelessWidget {
  const QrScreen({super.key});

  Future<void> _pick(BuildContext context, ImageSource source) async {
    if (!await requireAdmin(context) || !context.mounted) return;
    final store = TeamScope.of(context);
    final b64 = await ImageUtil.pickAsBase64(source: source, maxWidth: 800, quality: 80);
    if (b64 == null) return;
    await store.repo.updateSettings({'qrImage': b64});
    if (context.mounted) showSnack(context, 'Đã cập nhật ảnh QR');
  }

  Future<void> _editBankInfo(BuildContext context) async {
    if (!await requireAdmin(context) || !context.mounted) return;
    final store = TeamScope.of(context);
    final ctrl = TextEditingController(text: store.settings.bankInfo);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Thông tin chuyển khoản'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'VD: Vietcombank 0123456789 – NGUYEN VAN A\nNội dung: Tên + Quỹ PB',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
        ],
      ),
    );
    if (ok == true) await store.repo.updateSettings({'bankInfo': ctrl.text.trim()});
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final qr = store.settings.qrImageBase64;
    final bank = store.settings.bankInfo;

    return Scaffold(
      appBar: AppBar(
        title: const Text('QR chuyển khoản'),
        actions: [
          if (qr != null)
            IconButton(
              tooltip: 'Gửi QR lên Zalo',
              icon: const Icon(Icons.share),
              onPressed: () => ShareService.shareImageBase64(
                context,
                qr,
                fileName: 'qr-quy-pickleball.jpg',
                text: bank.isEmpty ? 'QR nộp quỹ pickleball' : '🏦 $bank',
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (qr == null)
            Container(
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.qr_code_2, size: 72),
                    SizedBox(height: 8),
                    Text('Chưa có ảnh QR. Thêm ảnh QR ngân hàng để mọi người quét chuyển khoản.'),
                  ],
                ),
              ),
            )
          else
            Base64Image(qr, height: 360, fit: BoxFit.contain),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () => _pick(context, ImageSource.gallery),
                icon: const Icon(Icons.photo_library),
                label: Text(qr == null ? 'Chọn ảnh QR' : 'Đổi ảnh QR'),
              ),
              OutlinedButton.icon(
                onPressed: () => _pick(context, ImageSource.camera),
                icon: const Icon(Icons.photo_camera),
                label: const Text('Chụp ảnh'),
              ),
              if (qr != null)
                TextButton.icon(
                  onPressed: () async {
                    if (await confirm(context, 'Xoá ảnh QR?')) {
                      await store.repo.updateSettings({'qrImage': null});
                    }
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Xoá'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.account_balance),
              title: const Text('Thông tin tài khoản'),
              subtitle: Text(bank.isEmpty ? 'Chưa nhập. Bấm để thêm số tài khoản.' : bank),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (bank.isNotEmpty)
                    IconButton(
                      tooltip: 'Sao chép',
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: bank));
                        showSnack(context, 'Đã sao chép');
                      },
                    ),
                  const Icon(Icons.edit),
                ],
              ),
              onTap: () => _editBankInfo(context),
            ),
          ),
        ],
      ),
    );
  }
}
