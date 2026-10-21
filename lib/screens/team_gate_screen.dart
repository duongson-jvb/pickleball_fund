import 'package:flutter/material.dart';

/// Màn hình nhập mã nhóm. Mọi thành viên dùng chung một mã để thấy
/// cùng dữ liệu. Mã nhóm hoạt động như "mật khẩu" của nhóm.
class TeamGateScreen extends StatefulWidget {
  const TeamGateScreen({super.key, required this.onJoin});
  final Future<void> Function(String teamId, String teamName) onJoin;

  @override
  State<TeamGateScreen> createState() => _TeamGateScreenState();
}

class _TeamGateScreenState extends State<TeamGateScreen> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController(text: 'Team Pickleball');
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onJoin(_code.text.trim().toLowerCase(), _name.text.trim());
    } catch (e) {
      setState(() => _error = 'Không kết nối được: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.sports_tennis, size: 72, color: Color(0xFF00897B)),
                  const SizedBox(height: 12),
                  Text('Quỹ Pickleball',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  const Text(
                    'Nhập mã nhóm để vào. Cả team dùng chung một mã, '
                    'ai có mã sẽ xem và cập nhật được quỹ.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _code,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Mã nhóm',
                      helperText: 'Ít nhất 6 ký tự, chữ/số, nên khó đoán',
                      prefixIcon: Icon(Icons.key),
                    ),
                    validator: (v) {
                      final s = (v ?? '').trim();
                      if (s.length < 6) return 'Mã nhóm cần ít nhất 6 ký tự';
                      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(s)) {
                        return 'Chỉ dùng chữ, số, gạch ngang / gạch dưới';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Tên nhóm (nếu tạo mới)',
                      prefixIcon: Icon(Icons.group),
                    ),
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _busy ? null : _submit,
                    icon: _busy
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.login),
                    label: const Text('Vào nhóm'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
