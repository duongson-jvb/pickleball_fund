import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'drink_types_screen.dart';
import 'qr_screen.dart';
import 'zalo_bot_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.teamId, required this.onLeaveTeam});
  final String teamId;
  final Future<void> Function() onLeaveTeam;

  Future<void> _editName(BuildContext context) async {
    final store = TeamScope.of(context);
    final ctrl = TextEditingController(text: store.settings.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tên nhóm'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      await store.repo.updateSettings({'name': ctrl.text.trim()});
    }
  }

  Future<void> _editThreshold(BuildContext context) async {
    final store = TeamScope.of(context);
    final ctrl = TextEditingController(text: store.settings.lowBalanceThreshold.toString());
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ngưỡng cảnh báo hết quỹ'),
        content: Form(
          key: form,
          child: AmountField(controller: ctrl, label: 'Báo khi số dư dưới', autofocus: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await store.repo.updateSettings({'lowBalanceThreshold': parseAmount(ctrl.text)});
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.group),
            title: const Text('Tên nhóm'),
            subtitle: Text(store.settings.name),
            trailing: const Icon(Icons.edit),
            onTap: () => _editName(context),
          ),
          ListTile(
            leading: const Icon(Icons.key),
            title: const Text('Mã nhóm'),
            subtitle: Text('$teamId  ·  gửi mã này cho thành viên để cùng dùng app'),
            trailing: const Icon(Icons.copy),
            onTap: () {
              Clipboard.setData(ClipboardData(text: teamId));
              showSnack(context, 'Đã sao chép mã nhóm');
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.warning_amber),
            title: const Text('Ngưỡng cảnh báo hết quỹ'),
            subtitle: Text('Báo khi số dư dưới ${vnd(store.settings.lowBalanceThreshold)}'),
            trailing: const Icon(Icons.edit),
            onTap: () => _editThreshold(context),
          ),
          ListTile(
            leading: const Icon(Icons.local_drink),
            title: const Text('Loại nước & giá'),
            subtitle: Text('${store.drinkTypes.where((d) => d.active).length} loại'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const DrinkTypesScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code),
            title: const Text('QR & thông tin chuyển khoản'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => const QrScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: const Text('Zalo Bot (vote tự động)'),
            subtitle: Text(store.settings.hasZaloBot
                ? 'Đã kết nối: ${store.settings.zaloBotName}'
                    '${store.settings.zaloGroupId.isEmpty ? ' · chưa chọn nhóm' : ''}'
                : 'Chưa kết nối'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const ZaloBotScreen())),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
            title: const Text('Đổi nhóm / thoát'),
            subtitle: const Text('Dữ liệu vẫn còn trên Firebase, vào lại bằng mã nhóm'),
            onTap: () async {
              if (await confirm(context, 'Thoát nhóm hiện tại?', okLabel: 'Thoát')) {
                await onLeaveTeam();
              }
            },
          ),
          const SizedBox(height: 24),
          Center(
            child: Text('Quỹ Pickleball · Firebase project pickleball-fund-phm',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
