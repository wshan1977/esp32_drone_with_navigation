import 'dart:async';

import 'package:flutter/material.dart';

import '../app/services.dart';

/// 펌웨어 CLI (MAVLink SERIAL_CONTROL). USB 시리얼 모니터와 같은 명령을 쓴다.
class ConsolePage extends StatefulWidget {
  final AppServices s;
  const ConsolePage({super.key, required this.s});

  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  StreamSubscription<String>? _sub;

  static const _quick = ['help', 'imu', 'tof', 'time', 'ps', 'wifi', 'sys', 'p'];

  @override
  void initState() {
    super.initState();
    _sub = widget.s.link.consoleStream.listen((_) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send(String cmd) {
    if (cmd.trim().isEmpty) return;
    widget.s.link.sendCli(cmd.trim());
    _input.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.s.link;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        Row(children: [
          for (final q in _quick)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(label: Text(q), onPressed: () => _send(q)),
            ),
          const Spacer(),
          TextButton.icon(
              onPressed: () => setState(link.clearConsole),
              icon: const Icon(Icons.delete_outline),
              label: const Text('지우기')),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(6)),
            child: SingleChildScrollView(
              controller: _scroll,
              child: SelectableText(link.consoleText,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 13, color: Color(0xFFD4D4D4))),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              decoration: const InputDecoration(
                  isDense: true, border: OutlineInputBorder(), hintText: '명령 입력 후 Enter (예: tof, p ACC_BIAS_X)'),
              style: const TextStyle(fontFamily: 'Consolas'),
              onSubmitted: _send,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: () => _send(_input.text), child: const Text('보내기')),
        ]),
      ]),
    );
  }
}
