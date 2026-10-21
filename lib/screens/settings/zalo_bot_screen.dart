import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/team_store.dart';
import '../../services/zalo_bot_service.dart';
import '../../services/zalo_vote_sync.dart';
import '../../utils/text.dart';
import '../../widgets/common.dart';

/// Cài đặt Zalo Bot: token, nhóm nhận vote, kiểm tra kết nối, người đã liên kết.
class ZaloBotScreen extends StatefulWidget {
  const ZaloBotScreen({super.key});

  @override
  State<ZaloBotScreen> createState() => _ZaloBotScreenState();
}

class _ZaloBotScreenState extends State<ZaloBotScreen> {
  final _token = TextEditingController();
  bool _busy = false;
  bool _listening = false;
  String? _status;
  final List<ZaloUpdate> _seen = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = TeamScope.of(context).settings;
      _token.text = s.zaloBotToken;
      _webhookUrl.text = s.zaloWebhookUrl;
      _webhookSecret.text = s.zaloWebhookSecret.isEmpty ? _randomSecret() : s.zaloWebhookSecret;
      setState(() {});
    });
  }

  Future<void> _saveToken() async {
    final store = TeamScope.of(context);
    final token = _token.text.trim();
    if (token.isEmpty) {
      showSnack(context, 'Dán Bot Token vào trước');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final info = await _bot(store, token: token).getMe();
      await store.repo.updateSettings({
        'zaloBotToken': token,
        'zaloBotName': info.displayName,
      });
      setState(() => _status =
          '✅ Kết nối OK: ${info.displayName}${info.canJoinGroups ? ' · được phép vào nhóm' : ' · KHÔNG được vào nhóm'}');
    } catch (e) {
      setState(() => _status = '❌ $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------- webhook
  final _webhookUrl = TextEditingController();
  final _webhookSecret = TextEditingController();

  /// Client Zalo theo cấu hình nhóm. Trên web dùng Worker làm proxy, lấy
  /// URL/secret đang gõ trong form (để dùng được ngay cả khi chưa bật webhook).
  ZaloBotService _bot(TeamStore store, {String? token, String? workerUrl, String? secret}) {
    final s = store.settings;
    final base = token == null
        ? s
        : TeamSettings(
            id: s.id,
            name: s.name,
            zaloBotToken: token,
            zaloWebhookUrl: s.zaloWebhookUrl,
            zaloWebhookSecret: s.zaloWebhookSecret,
          );
    return ZaloBotService.forTeam(
      base,
      store.repo.teamId,
      workerUrl: workerUrl ?? _webhookUrl.text.trim(),
      secret: secret ?? _webhookSecret.text.trim(),
    );
  }

  String _randomSecret() => randomSecret();

  Future<void> _enableWebhook() async {
    final store = TeamScope.of(context);
    var url = _webhookUrl.text.trim();
    final secret = _webhookSecret.text.trim();
    if (url.isEmpty || !url.startsWith('https://')) {
      showSnack(context, 'Nhập URL Worker dạng https://...workers.dev');
      return;
    }
    if (secret.length < 8) {
      showSnack(context, 'Secret cần ít nhất 8 ký tự (trùng với ZALO_SECRET trên Cloudflare)');
      return;
    }
    // Tự thêm /<mã nhóm> nếu người dùng chỉ dán URL gốc của Worker.
    final base = url.replaceAll(RegExp(r'/+$'), '');
    if (!base.endsWith('/${store.repo.teamId}')) url = '$base/${store.repo.teamId}';
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final msg = await _bot(store, workerUrl: url, secret: secret).setWebhook(url, secret);
      await store.repo.updateSettings({
        'zaloWebhookUrl': url,
        'zaloWebhookSecret': secret,
      });
      _webhookUrl.text = url;
      setState(() => _status = 'Webhook: $msg');
    } catch (e) {
      setState(() => _status = '❌ $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disableWebhook() async {
    final store = TeamScope.of(context);
    setState(() => _busy = true);
    try {
      await _bot(store).deleteWebhook();
      await store.repo.updateSettings({'zaloWebhookUrl': ''});
      setState(() => _status = 'Đã tắt webhook, app quay lại tự hỏi Zalo (getUpdates).');
    } catch (e) {
      setState(() => _status = '❌ $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Lắng nghe tin mới trong ~25 giây để tìm chat id của nhóm.
  Future<void> _listen() async {
    final store = TeamScope.of(context);
    final token = store.settings.zaloBotToken;
    if (token.isEmpty) {
      showSnack(context, 'Lưu Bot Token trước');
      return;
    }
    setState(() {
      _listening = true;
      _status = 'Đang lắng nghe 25 giây... Hãy vào nhóm Zalo, gõ @${store.settings.zaloBotName} và gửi.';
    });
    try {
      if (store.settings.zaloWebhookMode) {
        // Webhook đang bật: tin về qua Firestore, chỉ cần đợi rồi đọc zaloChats.
        await Future.delayed(const Duration(seconds: 25));
        if (!mounted) return;
        final n = TeamScope.of(context).settings.zaloChats.length;
        setState(() => _status = n == 0
            ? 'Chưa thấy tin nào qua webhook. Kiểm tra Worker (Logs) và bot đã trong nhóm chưa.'
            : 'Đã có $n chat. Chọn nhóm bên dưới.');
        return;
      }
      final updates = await _bot(store).getUpdates(timeoutSeconds: 25);
      setState(() {
        for (final u in updates) {
          _seen.removeWhere((s) => s.chatId == u.chatId);
          _seen.insert(0, u);
        }
        _status = updates.isEmpty
            ? 'Không nhận được tin nào. Kiểm tra bot đã được mời vào nhóm và thử lại.'
            : 'Nhận được ${updates.length} tin. Chọn nhóm bên dưới.';
      });
      // Tin nào là vote thì áp dụng luôn, không bỏ phí.
      await ZaloVoteSync.apply(store, updates);
    } catch (e) {
      setState(() => _status = '❌ $e');
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _manualGroupId() async {
    final store = TeamScope.of(context);
    final ctrl = TextEditingController(text: store.settings.zaloGroupId);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nhập chat_id nhóm'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
        ],
      ),
    );
    if (ok == true) {
      await store.repo.updateSettings({
        'zaloGroupId': ctrl.text.trim(),
        'zaloGroupName': 'Nhóm ${ctrl.text.trim()}',
      });
    }
  }

  Future<void> _sendTest() async {
    final store = TeamScope.of(context);
    final s = store.settings;
    if (s.zaloGroupId.isEmpty) {
      showSnack(context, 'Chưa chọn nhóm');
      return;
    }
    setState(() => _busy = true);
    try {
      await _bot(store).sendMessage(
        s.zaloGroupId,
        '🏓 ${s.name}: bot đã kết nối với app Quỹ Pickleball. '
        'Khi có vote, hãy Reply tin của bot: 1 = đi, 0 = không đi.',
      );
      if (mounted) showSnack(context, 'Đã gửi tin thử vào nhóm');
    } catch (e) {
      if (mounted) showSnack(context, 'Lỗi: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final s = store.settings;
    final linked = store.players.where((p) => p.zaloId.isNotEmpty).toList();
    // Gộp chat phát hiện trong phiên này với chat đã lưu trên Firestore.
    final chatMap = <String, ZaloChat>{...s.zaloChats};
    for (final u in _seen) {
      chatMap[u.chatId] = ZaloChat(
        chatId: u.chatId,
        isGroup: u.isGroup,
        lastFromName: u.fromName,
        lastText: u.text,
        lastDate: u.date,
      );
    }
    final chats = chatMap.values.toList()
      ..sort((a, b) => b.lastDate.compareTo(a.lastDate));
    final groups = chats.where((c) => c.isGroup).toList();
    final privates = chats.where((c) => !c.isGroup).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Zalo Bot')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '1. Trong Zalo, nhắn cho OA "Zalo Bot Manager" → Tạo bot → nhận Bot Token.\n'
            '2. Dán token vào đây và bấm Kiểm tra & lưu.\n'
            '3. Mở Bot Creator → "Mời Bot vào nhóm" → gửi link vào nhóm, trưởng nhóm bấm link.\n'
            '4. Bấm "Tìm nhóm", rồi vào nhóm gõ @tên bot để app nhận ra nhóm.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            decoration: InputDecoration(
              labelText: 'Bot Token',
              helperText: s.zaloBotName.isEmpty ? null : 'Đang dùng: ${s.zaloBotName}',
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => _token.clear(),
              ),
            ),
            maxLines: 2,
            minLines: 1,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _saveToken,
                icon: const Icon(Icons.verified),
                label: const Text('Kiểm tra & lưu'),
              ),
              const SizedBox(width: 8),
              if (s.hasZaloBot)
                TextButton(
                  onPressed: () async {
                    if (await confirm(context, 'Gỡ bot khỏi app?', okLabel: 'Gỡ')) {
                      await store.repo.updateSettings({
                        'zaloBotToken': '',
                        'zaloBotName': '',
                        'zaloGroupId': '',
                        'zaloGroupName': '',
                      });
                      _token.clear();
                    }
                  },
                  child: const Text('Gỡ bot'),
                ),
            ],
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status!),
            ),
          const Divider(height: 32),
          Text('Nhóm nhận vote', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.groups),
            title: Text(s.zaloGroupId.isEmpty ? 'Chưa chọn nhóm' : s.zaloGroupName),
            subtitle: Text(s.zaloGroupId.isEmpty
                ? 'Chưa chọn thì app nhận vote từ mọi chat (kể cả nhắn riêng cho bot)'
                : 'chat_id: ${s.zaloGroupId}'),
            trailing: IconButton(
              tooltip: 'Nhập tay chat_id',
              icon: const Icon(Icons.edit),
              onPressed: _manualGroupId,
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: (_listening || !s.hasZaloBot) ? null : _listen,
                icon: _listening
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.hearing),
                label: Text(_listening ? 'Đang lắng nghe...' : 'Tìm nhóm'),
              ),
              OutlinedButton.icon(
                onPressed: (_busy || s.zaloGroupId.isEmpty) ? null : _sendTest,
                icon: const Icon(Icons.send),
                label: const Text('Gửi tin thử'),
              ),
            ],
          ),
          if (groups.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Nhóm phát hiện được (bấm để chọn):'),
            for (final c in groups)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: Icon(Icons.group,
                      color: c.chatId == s.zaloGroupId ? Theme.of(context).colorScheme.primary : null),
                  title: Text('Nhóm · tin gần nhất từ ${c.lastFromName}'),
                  subtitle: Text('${c.lastText}\nchat_id: ${c.chatId}'),
                  isThreeLine: true,
                  selected: c.chatId == s.zaloGroupId,
                  trailing: c.chatId == s.zaloGroupId ? const Icon(Icons.check_circle) : null,
                  onTap: () => store.repo.updateSettings({
                    'zaloGroupId': c.chatId,
                    'zaloGroupName': 'Nhóm Zalo (${c.lastFromName} đã @bot)',
                  }),
                ),
              ),
          ],
          if (privates.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
                'Tin nhắn riêng: ${privates.map((c) => '${c.lastFromName}: "${c.lastText}"').join(' · ')}',
                style: Theme.of(context).textTheme.bodySmall),
          ],
          const Divider(height: 32),
          Text('Webhook (Cloudflare Worker) – nhận vote mọi lúc',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            s.zaloWebhookMode
                ? '✅ Đang bật. Zalo đẩy tin về Worker → Firestore, app tự xử lý khi mở. '
                    'Chế độ tự hỏi Zalo (getUpdates) bị tắt.'
                : 'Chưa bật. Hiện app chỉ nhận vote khi đang mở tab Vote. '
                    'Xem hướng dẫn tạo Worker trong thư mục worker/ của dự án.',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _webhookUrl,
            decoration: InputDecoration(
              labelText: 'URL Worker',
              hintText: 'https://pickleball-zalo-webhook.<ten>.workers.dev',
              helperText: 'App tự thêm /${store.repo.teamId} vào cuối',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _webhookSecret,
            decoration: InputDecoration(
              labelText: 'Secret (ZALO_SECRET trên Cloudflare)',
              suffixIcon: IconButton(
                tooltip: 'Tạo chuỗi mới',
                icon: const Icon(Icons.casino_outlined),
                onPressed: () => setState(() => _webhookSecret.text = _randomSecret()),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: (_busy || !s.hasZaloBot) ? null : _enableWebhook,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(s.zaloWebhookMode ? 'Cập nhật webhook' : 'Bật webhook'),
              ),
              if (s.zaloWebhookMode)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _disableWebhook,
                  icon: const Icon(Icons.cloud_off_outlined),
                  label: const Text('Tắt webhook'),
                ),
            ],
          ),
          const Divider(height: 32),
          Text('Người chơi đã liên kết Zalo (${linked.length})',
              style: Theme.of(context).textTheme.titleMedium),
          const Text(
            'Lần đầu bot khớp theo tên hiển thị Zalo, sau đó nhớ Zalo id. '
            'Nếu khớp sai, bấm gỡ liên kết rồi gán lại ở tab Vote.',
            style: TextStyle(fontSize: 12),
          ),
          for (final p in linked)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link),
              title: Text(p.name),
              subtitle: Text('Zalo: ${p.zaloName.isEmpty ? p.zaloId : p.zaloName}'),
              trailing: IconButton(
                tooltip: 'Gỡ liên kết',
                icon: const Icon(Icons.link_off),
                onPressed: () =>
                    store.repo.updatePlayer(p.id, {'zaloId': '', 'zaloName': ''}),
              ),
            ),
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            margin: EdgeInsets.zero,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Lưu ý: bot chỉ nhận được tin khi thành viên Reply tin của bot hoặc @mention bot. '
                'App lấy tin bằng cách hỏi Zalo (getUpdates) khi bạn mở tab Vote hoặc bấm Đồng bộ, '
                'nên hãy mở app sau khi mọi người vote. Token được lưu trong dữ liệu nhóm trên Firebase.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
