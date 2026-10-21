import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/image_util.dart';
import '../utils/format.dart';

/// Ô nhập số tiền (chấp nhận 50k, 1tr, 50.000...).
class AmountField extends StatelessWidget {
  const AmountField({
    super.key,
    required this.controller,
    this.label = 'Số tiền',
    this.autofocus = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        suffixText: 'đ',
        helperText: 'Ví dụ: 50000, 50k, 1tr',
      ),
      validator: (v) => parseAmount(v ?? '') <= 0 ? 'Nhập số tiền hợp lệ' : null,
      onChanged: (v) => onChanged?.call(parseAmount(v)),
    );
  }
}

/// Hộp thoại xác nhận đơn giản. Trả về true nếu đồng ý.
Future<bool> confirm(BuildContext context, String title,
    {String? message, String okLabel = 'Xoá', bool danger = true}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Huỷ')),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(okLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Chọn nhiều người chơi bằng chip.
class PlayerMultiSelect extends StatelessWidget {
  const PlayerMultiSelect({
    super.key,
    required this.players,
    required this.selected,
    required this.onChanged,
    this.balances,
  });

  final List<Player> players;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final Map<String, int>? balances;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TextButton(
              onPressed: () => onChanged(players.map((p) => p.id).toSet()),
              child: const Text('Chọn tất cả'),
            ),
            TextButton(
              onPressed: () => onChanged({}),
              child: const Text('Bỏ chọn'),
            ),
            const Spacer(),
            Text('${selected.length}/${players.length}'),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final p in players)
              FilterChip(
                label: Text(balances == null
                    ? p.name
                    : '${p.name} (${vnd(balances![p.id] ?? 0)})'),
                selected: selected.contains(p.id),
                onSelected: (v) {
                  final next = {...selected};
                  v ? next.add(p.id) : next.remove(p.id);
                  onChanged(next);
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// Hiển thị ảnh base64, bấm để xem toàn màn hình.
class Base64Image extends StatelessWidget {
  const Base64Image(this.base64, {super.key, this.height = 200, this.fit = BoxFit.cover});
  final String base64;
  final double height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final Uint8List bytes = ImageUtil.decode(base64);
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(),
            backgroundColor: Colors.black,
            body: Center(
              child: InteractiveViewer(child: Image.memory(bytes)),
            ),
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(bytes, height: height, width: double.infinity, fit: fit),
      ),
    );
  }
}

/// Số tiền có màu: dương xanh, âm đỏ.
class MoneyText extends StatelessWidget {
  const MoneyText(this.amount,
      {super.key, this.signed = false, this.style, this.warnBelow});
  final int amount;
  final bool signed;
  final TextStyle? style;
  final int? warnBelow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color color;
    if (amount < 0) {
      color = scheme.error;
    } else if (warnBelow != null && amount < warnBelow!) {
      color = Colors.orange.shade800;
    } else {
      color = Colors.green.shade700;
    }
    return Text(
      signed ? vndSigned(amount) : vnd(amount),
      style: (style ?? const TextStyle(fontWeight: FontWeight.w600))
          .copyWith(color: color),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key, this.icon = Icons.inbox_outlined});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor)),
          ],
        ),
      ),
    );
  }
}

/// Chọn ngày bằng ListTile.
class DateTile extends StatelessWidget {
  const DateTile({super.key, required this.date, required this.onChanged, this.label = 'Ngày'});
  final DateTime date;
  final ValueChanged<DateTime> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.calendar_today_outlined),
      title: Text(label),
      subtitle: Text(fmtWeekday(date)),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (picked != null) {
          onChanged(DateTime(picked.year, picked.month, picked.day, date.hour, date.minute));
        }
      },
    );
  }
}
