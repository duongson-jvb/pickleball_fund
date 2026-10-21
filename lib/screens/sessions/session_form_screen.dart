import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/models.dart';
import '../../services/image_util.dart';
import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'session_detail_screen.dart';

/// Tạo mới / sửa thông tin buổi chơi (ngày, sân, tiền sân, ảnh đặt sân).
class SessionFormScreen extends StatefulWidget {
  const SessionFormScreen({super.key, this.session});
  final Session? session;

  @override
  State<SessionFormScreen> createState() => _SessionFormScreenState();
}

class _SessionFormScreenState extends State<SessionFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _fee;
  late final TextEditingController _note;
  late DateTime _date;
  String? _image;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final s = widget.session;
    final now = DateTime.now();
    _title = TextEditingController(text: s?.title ?? '');
    _location = TextEditingController(text: s?.location ?? '');
    _fee = TextEditingController(text: s == null || s.courtFee == 0 ? '' : s.courtFee.toString());
    _note = TextEditingController(text: s?.note ?? '');
    _date = s?.date ?? DateTime(now.year, now.month, now.day, 18, 0);
    _image = s?.courtImageBase64;
  }

  Future<void> _pickImage(ImageSource source) async {
    final b64 = await ImageUtil.pickAsBase64(source: source);
    if (b64 != null) setState(() => _image = b64);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_date));
    if (t != null) {
      setState(() => _date = DateTime(_date.year, _date.month, _date.day, t.hour, t.minute));
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final store = TeamScope.of(context);
    setState(() => _busy = true);
    try {
      final fee = parseAmount(_fee.text);
      if (widget.session == null) {
        final s = Session(
          id: '',
          title: _title.text.trim(),
          date: _date,
          location: _location.text.trim(),
          courtFee: fee,
          courtImageBase64: _image,
          note: _note.text.trim(),
          drinkPrices: store.defaultDrinkPrices(_date),
          createdAt: DateTime.now(),
        );
        final id = await store.repo.createSession(s);
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => SessionDetailScreen(sessionId: id)),
        );
      } else {
        // Lấy bản mới nhất (vote có thể vừa về) rồi chỉ ghi đè các trường của form.
        final latest = store.sessions
                .where((x) => x.id == widget.session!.id)
                .firstOrNull ??
            widget.session!;
        final s = latest.copyWith(
          title: _title.text.trim(),
          date: _date,
          location: _location.text.trim(),
          courtFee: fee,
          courtImageBase64: _image,
          clearCourtImage: _image == null,
          note: _note.text.trim(),
        );
        await store.repo.saveAndSettleSession(
          s,
          commonFundExcludingThis: store.commonFundExcluding(s.id),
        );
        if (mounted) Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.session == null;
    return Scaffold(
      appBar: AppBar(title: Text(isNew ? 'Tạo buổi chơi' : 'Sửa buổi chơi')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Tiêu đề (VD: Thứ 7 sân A)'),
            ),
            Row(
              children: [
                Expanded(
                  child: DateTile(
                      label: 'Ngày chơi', date: _date, onChanged: (d) => setState(() => _date = d)),
                ),
                TextButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.schedule),
                  label: Text(TimeOfDay.fromDateTime(_date).format(context)),
                ),
              ],
            ),
            TextFormField(
              controller: _location,
              decoration: const InputDecoration(labelText: 'Địa điểm / sân'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _fee,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Tiền sân (có thể nhập sau)',
                suffixText: 'đ',
                helperText: 'Ưu tiên trừ quỹ chung, thiếu thì chia đều cho người chơi',
              ),
            ),
            const SizedBox(height: 12),
            Text('Ảnh đặt sân', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            if (_image != null) ...[
              Base64Image(_image!, height: 180),
              const SizedBox(height: 6),
            ],
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _pickImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library),
                  label: Text(_image == null ? 'Chọn ảnh' : 'Đổi ảnh'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _pickImage(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('Chụp'),
                ),
                if (_image != null)
                  TextButton.icon(
                    onPressed: () => setState(() => _image = null),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Xoá ảnh'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Ghi chú'),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: Icon(isNew ? Icons.how_to_vote : Icons.check),
              label: Text(isNew ? 'Tạo & mở vote' : 'Lưu & tính lại tiền'),
            ),
          ],
        ),
      ),
    );
  }
}
