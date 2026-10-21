import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../../services/share_service.dart';
import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

/// Chọn thông tin muốn chia sẻ lên Zalo, xem trước rồi gửi.
class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key, this.session});
  final Session? session;

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  bool _balances = true;
  bool _low = true;
  bool _common = true;
  bool _session = false;
  bool _bank = true;
  bool _qrImage = false;
  String? _sessionId;
  final _extra = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.session != null) {
      _session = true;
      _sessionId = widget.session!.id;
      _balances = false;
      _low = false;
      _common = false;
    }
  }

  String _build(TeamStore store) {
    final parts = <String>[];
    if (_extra.text.trim().isNotEmpty) parts.add(_extra.text.trim());
    if (_session && _sessionId != null) {
      final s = store.sessions.where((s) => s.id == _sessionId).firstOrNull;
      if (s != null) parts.add(ShareService.sessionReport(store, s));
    }
    if (_balances) parts.add(ShareService.balanceReport(store));
    if (_low) parts.add(ShareService.lowBalanceReport(store));
    if (_common && !_balances) parts.add(ShareService.commonFundReport(store));
    if (_bank) {
      final b = ShareService.bankInfo(store);
      if (b.isNotEmpty) parts.add(b);
    }
    return parts.join('\n\n');
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final text = _build(store);
    final sessions = store.sessions.take(20).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Chia sẻ lên Zalo')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          CheckboxListTile(
            value: _balances,
            onChanged: (v) => setState(() => _balances = v!),
            title: const Text('Số dư tất cả người chơi'),
          ),
          CheckboxListTile(
            value: _low,
            onChanged: (v) => setState(() => _low = v!),
            title: Text('Danh sách sắp hết quỹ (${store.lowBalancePlayers.length})'),
          ),
          CheckboxListTile(
            value: _common,
            onChanged: (v) => setState(() => _common = v!),
            title: Text('Quỹ chung (${vnd(store.commonFund)})'),
          ),
          CheckboxListTile(
            value: _session,
            onChanged: sessions.isEmpty ? null : (v) => setState(() {
              _session = v!;
              _sessionId ??= sessions.first.id;
            }),
            title: const Text('Tổng kết buổi chơi'),
            subtitle: _session
                ? DropdownButton<String>(
                    isExpanded: true,
                    value: _sessionId,
                    items: [
                      for (final s in sessions)
                        DropdownMenuItem(
                          value: s.id,
                          child: Text('${fmtDate(s.date)} ${s.title}',
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _sessionId = v),
                  )
                : null,
          ),
          CheckboxListTile(
            value: _bank,
            onChanged: (v) => setState(() => _bank = v!),
            title: const Text('Thông tin chuyển khoản'),
          ),
          CheckboxListTile(
            value: _qrImage,
            onChanged: store.settings.qrImageBase64 == null
                ? null
                : (v) => setState(() => _qrImage = v!),
            title: const Text('Đính kèm ảnh QR'),
            subtitle: store.settings.qrImageBase64 == null
                ? const Text('Chưa có ảnh QR')
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _extra,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Lời nhắn thêm (tuỳ chọn)'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Xem trước', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(text.isEmpty ? '(Chưa chọn nội dung)' : text),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: text.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: text));
                            showSnack(context, 'Đã sao chép, dán vào Zalo');
                          },
                    icon: const Icon(Icons.copy),
                    label: const Text('Sao chép'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: text.isEmpty && !_qrImage
                        ? null
                        : () {
                            if (_qrImage && store.settings.qrImageBase64 != null) {
                              ShareService.shareImageBase64(
                                context,
                                store.settings.qrImageBase64!,
                                fileName: 'qr-quy-pickleball.jpg',
                                text: text,
                              );
                            } else {
                              ShareService.shareText(context, text);
                            }
                          },
                    icon: const Icon(Icons.share),
                    label: const Text('Chia sẻ'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
