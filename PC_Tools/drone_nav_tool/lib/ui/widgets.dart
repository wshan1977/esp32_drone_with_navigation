import 'package:flutter/material.dart';

class StatusDot extends StatelessWidget {
  final bool ok;
  final String label;
  final String tooltip;
  const StatusDot({super.key, required this.ok, required this.label, this.tooltip = ''});

  @override
  Widget build(BuildContext context) {
    final row = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 12, color: ok ? Colors.green : Colors.grey),
      const SizedBox(width: 6),
      Text(label),
    ]);
    return tooltip.isEmpty ? row : Tooltip(message: tooltip, child: row);
  }
}

class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const InfoRow(this.label, this.value, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 90, child: Text(label, style: TextStyle(color: Colors.grey.shade700))),
        Expanded(
            child: Text(value,
                style: TextStyle(fontWeight: FontWeight.w600, color: color, fontFeatures: const [
                  FontFeature.tabularFigures(),
                ]))),
      ]),
    );
  }
}

void showSnack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
