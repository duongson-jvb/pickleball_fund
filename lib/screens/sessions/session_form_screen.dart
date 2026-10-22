import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/models.dart';
import '../../services/image_util.dart';
import '../../services/team_store.dart';
import '../../utils/format.dart';
import '../../widgets/admin_gate.dart';
import '../../widgets/common.dart';
import 'session_detail_screen.dart';

/// Tạo mới / sửa thông tin buổi chơi (ngày, sân, tiền sân, ảnh đặt sân,
/// người tạo, hạn vote, giới hạn số người).
class SessionFormScreen extends StatefulWidget {
  const SessionFormScreen({super.key, this.session});
  final Session? session;

  @override
  State<SessionFormScreen> createState() => _SessionFormScreenState();
}

class _SessionFormScreenState extends State<SessionFormScreen> {
  static const minVoteWindow = Duration(minutes: 30);

  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _fee;
  late final TextEditingController _note;
  late final TextEditingController _creator;
  late final TextEditingController _maxPlayers;
  late DateTime _date;
  late DateTime _deadline;
  bool _deadlineEdited = false;
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
    _creator = TextEditingController(text: s?.createdByName ?? '');
    _maxPlayers = TextEditingController(text: s?.maxPlayers?.toString() ?? '');
    _date = s?.date ?? DateTime(now.year, now.month, now.day + 1, 18, 0);
    _deadline = s?.voteDeadline ?? _date;
    _deadlineEdited = s?.voteDeadline != null;
    _image = s?.courtImageBase64;
  }

  Future<void> _pickImage(ImageSource source) async {
    final b64 = await ImageUtil.pickAsBase64(source: source);
    if (b64 != null) setState(() => _image = b64);
  }

  void _setDate(DateTime d) {
    setState(() {
      _date = d;
      // Hạn vote mặc định = giờ bắt đầu chơi, và không bao giờ muộn hơn giờ chơi.
      if (!_deadlineEdited || _deadline.isAfter(d)) _deadline = d;
    });
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_date));
    if (t != null) {
      _setDate(DateTime(_date.year, _date.month, _date.day, t.hour, t.minute));
    }
  }

  Future<void> _pickDeadline() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _deadline.isAfter(_date) ? _date : _deadline,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: _date,
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_deadline));
    if (t == null) return;
    var picked = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    if (picked.isAfter(_date)) picked = _date;
    setState(() {
      _deadline = picked;
      _deadlineEdited = true;
    });
  }

  /// Kiểm tra hạn vote: không muộn hơn giờ chơi, và cách lúc này ít nhất 30 phút
  /// (trừ khi giờ chơi đã quá gần, khi đó hạn = giờ chơi).
  String? _deadlineError() {
    if (_deadline.isAfter(_date)) return 'Hạn vote không được sau giờ bắt đầu chơi';
    final isNew = widget.session == null;
    final minDeadline = DateTime.now().add(minVoteWindow);
    if (isNew && _deadline.isBefore(minDeadline) && _date.isAfter(minDeadline)) {
      return 'Hạn vote phải cách bây giờ ít nhất 30 phút';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final dlErr = _deadlineError();
    if (dlErr != null) {
      showSnack(context, dlErr);
      return;
    }
    if (!await requireAdmin(context) || !mounted) return;
    final store = TeamScope.of(context);
    setState(() => _busy = true);
    try {
      final fee = parseAmount(_fee.text);
      final creatorName = _creator.text.trim();
      final creator = store.players
          .where((p) => p.name.trim().toLowerCase() == creatorName.toLowerCase())
          .firstOrNull;
      final maxText = _maxPlayers.text.trim();
      final max = maxText.isEmpty ? null : int.tryParse(maxText);
      // Hạn vote trùng giờ chơi thì không cần lưu riêng (mặc định).
      final deadline = _deadline.isAtSameMomentAs(_date) ? null : _deadline;

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
          createdByName: creatorName,
          createdById: creator?.id ?? '',
          voteDeadline: deadline,
          maxPlayers: max,
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
          createdByName: creatorName,
          createdById: creator?.id ?? '',
          voteDeadline: deadline,
          clearVoteDeadline: deadline == null,
          maxPlayers: max,
          clearMaxPlayers: max == null,
        );
        await store.repo.saveAndSettleSession(s);
        if (mounted) Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TeamScope.of(context);
    final isNew = widget.session == null;
    final names = store.activePlayers.map((p) => p.name).toList();
    final dlErr = _deadlineError();

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
            const SizedBox(height: 12),
            // Người tạo buổi: bắt buộc, gợi ý từ danh sách người chơi.
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _creator.text),
              optionsBuilder: (v) {
                final q = v.text.trim().toLowerCase();
                if (q.isEmpty) return names;
                return names.where((n) => n.toLowerCase().contains(q));
              },
              onSelected: (v) => _creator.text = v,
              fieldViewBuilder: (ctx, ctrl, focus, onSubmit) {
                ctrl.addListener(() => _creator.text = ctrl.text);
                return TextFormField(
                  controller: ctrl,
                  focusNode: focus,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Người tạo buổi chơi *',
                    prefixIcon: Icon(Icons.person_pin_outlined),
                    helperText: 'Chọn từ danh sách hoặc gõ tên',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Nhập người tạo buổi chơi' : null,
                );
              },
            ),
            Row(
              children: [
                Expanded(
                  child: DateTile(label: 'Ngày chơi', date: _date, onChanged: _setDate),
                ),
                TextButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.schedule),
                  label: Text(TimeOfDay.fromDateTime(_date).format(context)),
                ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Hạn vote'),
              subtitle: Text(
                '${fmtDateTime(_deadline)}'
                '${_deadline.isAtSameMomentAs(_date) ? ' (= giờ bắt đầu chơi)' : ''}'
                '${dlErr != null ? '\n$dlErr' : ''}',
                style: dlErr != null ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
              ),
              trailing: const Icon(Icons.edit),
              onTap: _pickDeadline,
            ),
            TextFormField(
              controller: _maxPlayers,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Giới hạn số người chơi',
                helperText: 'Để trống = không giới hạn. Đủ người thì không nhận thêm vote "đi".',
                prefixIcon: Icon(Icons.groups_outlined),
              ),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return null;
                final n = int.tryParse(t);
                if (n == null || n <= 0) return 'Nhập số nguyên dương hoặc để trống';
                return null;
              },
            ),
            const SizedBox(height: 12),
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
