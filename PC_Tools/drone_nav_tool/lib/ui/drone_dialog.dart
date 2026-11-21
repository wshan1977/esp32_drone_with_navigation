import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app/services.dart';
import '../drone/serial_setup.dart';
import 'widgets.dart';

/// 드론 연결: 드론이 공유기(STA)에 접속하면 하트비트 브로드캐스트로 자동 연결된다.
/// 처음 한 번은 USB로 공유기 SSID/비밀번호를 넣는다 (펌웨어 `sta` 명령).
class DroneDialog extends StatefulWidget {
  final AppServices s;
  const DroneDialog({super.key, required this.s});

  static Future<void> show(BuildContext context, AppServices s) =>
      showDialog(context: context, builder: (_) => DroneDialog(s: s));

  @override
  State<DroneDialog> createState() => _DroneDialogState();
}

class _DroneDialogState extends State<DroneDialog> {
  final _ssidCtl = TextEditingController();
  final _passCtl = TextEditingController();
  late final _ipCtl = TextEditingController(text: widget.s.settings.droneIp);
  final _logScroll = ScrollController();
  List<SerialPortEntry> _ports = [];
  String? _port;
  bool _showPass = false;
  bool _busy = false;
  String _log = '';
  String _error = '';

  List<String> _pcIps = [];

  @override
  void initState() {
    super.initState();
    _refreshPorts();
    NetworkInterface.list(type: InternetAddressType.IPv4).then((ifs) {
      if (!mounted) return;
      setState(() => _pcIps = [
            for (final i in ifs)
              for (final a in i.addresses) a.address,
          ]);
    });
  }

  @override
  void dispose() {
    _ssidCtl.dispose();
    _passCtl.dispose();
    _ipCtl.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  void _refreshPorts() {
    try {
      _ports = SerialSession.list();
    } catch (e) {
      _ports = [];
      _error = '시리얼 포트 목록을 읽지 못함: $e';
    }
    if (_port == null || !_ports.any((p) => p.name == _port)) {
      _port = _ports.where((p) => p.looksLikeUsb).firstOrNull?.name ?? _ports.firstOrNull?.name;
    }
    setState(() {});
  }

  void _appendLog(String s) {
    if (!mounted) return;
    setState(() => _log = (_log + s).length > 8000 ? (_log + s).substring((_log + s).length - 8000) : _log + s);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  String? _validate() {
    final ssid = _ssidCtl.text.trim();
    if (ssid.isEmpty) return '공유기 SSID를 입력하세요';
    if (ssid.contains(' ')) return 'SSID에 공백이 있으면 펌웨어 명령으로 보낼 수 없습니다';
    return null;
  }

  /// USB로 `sta <ssid> <pw>` + `reboot`을 보내고 접속 결과(IP)를 보여준다.
  Future<void> _sendUsb({bool apMode = false}) async {
    final err = apMode ? null : _validate();
    if (err != null || _port == null) {
      setState(() => _error = err ?? 'USB 포트를 고르세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _log = '';
    });
    SerialSession? ser;
    StreamSubscription<String>? sub;
    try {
      ser = SerialSession.open(_port!);
      sub = ser.output.listen(_appendLog);
      _appendLog('[$_port 열림 — 드론 부팅 대기]\n');
      await Future.delayed(const Duration(seconds: 3)); // 포트를 열 때 DevKit이 리셋될 수 있음
      ser.sendLine(apMode ? 'ap' : 'sta ${_ssidCtl.text.trim()} ${_passCtl.text}');
      await Future.delayed(const Duration(milliseconds: 600));
      ser.sendLine('reboot');
      _appendLog('\n[재부팅 — 공유기 접속 대기 (최대 25초)]\n');
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline) && mounted) {
        if (_log.contains('Wi-Fi connected') || (apMode && _log.contains('Wi-Fi AP'))) break;
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (!apMode && !_log.contains('Wi-Fi connected')) {
        _error = '드론이 공유기에 접속하지 못했습니다. SSID/비밀번호와 2.4GHz 대역인지 확인하세요.';
      }
    } catch (e) {
      _error = '$e'.replaceFirst('Exception: ', '');
    } finally {
      await sub?.cancel();
      ser?.close();
    }
    if (mounted) setState(() => _busy = false);
  }

  /// 이미 연결된 드론에 네트워크로 새 공유기 정보를 보낸다.
  void _sendOverLink() {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    widget.s.link.sendCli('sta ${_ssidCtl.text.trim()} ${_passCtl.text}');
    Future.delayed(const Duration(milliseconds: 500), () => widget.s.link.sendCli('reboot'));
    showSnack(context, '설정을 보냈습니다. 드론이 재부팅 후 새 공유기에 접속합니다.');
  }

  void _applyIp() {
    widget.s.settings.droneIp = _ipCtl.text.trim();
    widget.s.settings.save();
    widget.s.link.setManualAddress(_ipCtl.text);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.s.link,
      builder: (context, _) {
        final link = widget.s.link;
        return AlertDialog(
          title: const Text('드론 연결'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                StatusDot(
                  ok: link.connected,
                  label: link.connected
                      ? '연결됨: ${link.droneAddress?.address}'
                      : '찾는 중 — 드론이 이 PC와 같은 공유기에 접속하면 자동으로 연결됩니다',
                ),
                if (link.bindError.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(link.bindError, style: const TextStyle(color: Colors.orange)),
                  ),
                const SizedBox(height: 6),
                Text(
                  '진단 · UDP 14550 ${link.socketOpen ? "열림" : "닫힘(재시도 중)"} · 받은 패킷 ${link.rxPackets}'
                  '${link.lastRxFrom.isEmpty ? "" : " · 마지막 ${link.lastRxFrom} (${DateTime.now().difference(link.lastRxTime!).inSeconds}초 전)"}'
                  ' · 이 PC ${_pcIps.join(", ")}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const Divider(height: 28),
                const Text('드론을 공유기에 연결', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Text('LocationX와 같은 공유기(2.4GHz)의 이름과 비밀번호를 드론에 저장합니다. 처음 한 번은 USB 케이블로 보냅니다.',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _ssidCtl,
                      decoration: const InputDecoration(labelText: '공유기 SSID', isDense: true, border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _passCtl,
                      obscureText: !_showPass,
                      decoration: InputDecoration(
                        labelText: '비밀번호',
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility, size: 18),
                          onPressed: () => setState(() => _showPass = !_showPass),
                        ),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  const Text('USB 포트 '),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _port,
                      hint: const Text('포트 없음 — 드론을 USB로 연결하세요'),
                      items: [
                        for (final p in _ports)
                          DropdownMenuItem(value: p.name, child: Text('${p.name}  ${p.description}', overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: _busy ? null : (v) => setState(() => _port = v),
                    ),
                  ),
                  IconButton(tooltip: '새로고침', onPressed: _busy ? null : _refreshPorts, icon: const Icon(Icons.refresh)),
                ]),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _sendUsb(),
                    icon: const Icon(Icons.usb),
                    label: Text(_busy ? '진행 중…' : 'USB로 설정 보내기'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || !link.connected ? null : _sendOverLink,
                    icon: const Icon(Icons.wifi),
                    label: const Text('현재 연결로 보내기'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _sendUsb(apMode: true),
                    child: const Text('USB로 AP 모드 복귀'),
                  ),
                ]),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_error, style: const TextStyle(color: Colors.red)),
                ],
                if (_log.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    height: 160,
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: const Color(0xFF1E1E1E),
                    child: SingleChildScrollView(
                      controller: _logScroll,
                      child: SelectableText(_log,
                          style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, color: Color(0xFFD4D4D4))),
                    ),
                  ),
                ],
                const Divider(height: 28),
                Text('공유기에 접속하지 못하면 드론은 30초 뒤 복구용 AP(XW_Drone_WiFi)를 켭니다.\n'
                    'Windows 방화벽이 물으면 이 프로그램의 UDP 통신을 허용하세요.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _ipCtl,
                      decoration: const InputDecoration(
                          labelText: '수동 IP (브로드캐스트가 막힌 망에서만, 비우면 자동)',
                          isDense: true,
                          border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: _applyIp, child: const Text('적용')),
                ]),
              ]),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기'))],
        );
      },
    );
  }
}
