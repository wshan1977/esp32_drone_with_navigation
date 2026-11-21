import 'package:flutter/material.dart';

import '../app/services.dart';

/// 펌웨어 파라미터 목록 읽기·수정 (MAVLink PARAM_*). 수정값은 드론이 약 1초 뒤 플래시에 저장한다.
class ParamsPage extends StatefulWidget {
  final AppServices s;
  const ParamsPage({super.key, required this.s});

  @override
  State<ParamsPage> createState() => _ParamsPageState();
}

class _ParamsPageState extends State<ParamsPage> {
  String _filter = '';

  Future<void> _edit(String name, double value) async {
    final ctl = TextEditingController(text: _fmt(value));
    final v = await showDialog<double>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(name),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          onSubmitted: (t) => Navigator.pop(c, double.tryParse(t)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, double.tryParse(ctl.text)), child: const Text('저장')),
        ],
      ),
    );
    if (v != null) widget.s.link.setParam(name, v);
  }

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.s.link,
      builder: (context, _) {
        final link = widget.s.link;
        final entries = link.params.entries
            .where((e) => e.key.toLowerCase().contains(_filter.toLowerCase()))
            .toList();
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              FilledButton.icon(
                onPressed: link.connected ? link.requestParams : null,
                icon: const Icon(Icons.download),
                label: const Text('드론에서 읽기'),
              ),
              const SizedBox(width: 12),
              Text('${link.params.length} / ${link.paramCount}'),
              const SizedBox(width: 24),
              SizedBox(
                width: 240,
                child: TextField(
                  decoration: const InputDecoration(
                      isDense: true, prefixIcon: Icon(Icons.search), hintText: '이름 검색', border: OutlineInputBorder()),
                  onChanged: (t) => setState(() => _filter = t),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: Card(
                child: ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, i) => ListTile(
                    dense: true,
                    title: Text(entries[i].key, style: const TextStyle(fontFamily: 'Consolas')),
                    trailing: Text(_fmt(entries[i].value),
                        style: const TextStyle(fontFamily: 'Consolas', fontWeight: FontWeight.bold)),
                    onTap: () => _edit(entries[i].key, entries[i].value),
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }
}
