import 'package:flutter/material.dart';

import '../aoa/locationx_api.dart';
import '../app/services.dart';

/// LocationX 연결 설정: 내부망(서버 카드 검색) 또는 외부망(중계 브로커 + siteId).
class LocationXDialog extends StatefulWidget {
  final AppServices s;
  const LocationXDialog({super.key, required this.s});

  static Future<void> show(BuildContext context, AppServices s) =>
      showDialog(context: context, builder: (_) => LocationXDialog(s: s));

  @override
  State<LocationXDialog> createState() => _LocationXDialogState();
}

class _LocationXDialogState extends State<LocationXDialog> {
  late final _serverCtl = TextEditingController(text: widget.s.settings.serverIp);
  late final _brokerCtl = TextEditingController(text: widget.s.settings.brokerHost);
  late final _cloudHostCtl = TextEditingController(text: widget.s.settings.cloudHost);
  late final _cloudPortCtl = TextEditingController(text: '${widget.s.settings.cloudPort}');
  late final _siteCtl = TextEditingController(text: widget.s.settings.siteId);
  late int _tab = widget.s.settings.cloud ? 1 : 0;

  List<LxDevice>? _found;
  bool _scanning = false;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    if (!widget.s.settings.cloud) _scan();
  }

  @override
  void dispose() {
    for (final c in [_serverCtl, _brokerCtl, _cloudHostCtl, _cloudPortCtl, _siteCtl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = '';
    });
    try {
      final list = await LocationXApi.discover();
      _found = list;
      final servers = list.where((d) => d.isServer).toList();
      if (servers.length == 1 && _serverCtl.text.isEmpty) _select(servers.first);
    } catch (e) {
      _error = '검색 실패: $e';
    }
    if (mounted) setState(() => _scanning = false);
  }

  void _select(LxDevice d) {
    _serverCtl.text = d.ip;
    _brokerCtl.text = d.mqttHost.isEmpty || d.mqttHost == '127.0.0.1' || d.mqttHost == 'localhost'
        ? d.ip
        : d.mqttHost;
    setState(() {});
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (_tab == 0) {
        if (_serverCtl.text.trim().isEmpty) throw Exception('서버 카드 IP를 입력하거나 검색에서 고르세요');
        await widget.s.connectLan(_serverCtl.text, brokerHost: _brokerCtl.text);
      } else {
        widget.s.settings
          ..cloudHost = _cloudHostCtl.text.trim()
          ..cloudPort = int.tryParse(_cloudPortCtl.text.trim()) ?? 1883
          ..siteId = _siteCtl.text.trim();
        if (widget.s.settings.cloudHost.isEmpty || widget.s.settings.siteId.isEmpty) {
          throw Exception('브로커 주소와 siteId를 입력하세요');
        }
        await widget.s.connectCloud();
      }
      final aoa = widget.s.aoa;
      if (aoa.error.isNotEmpty) throw Exception(aoa.error);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _error = '$e'.replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('LocationX 연결'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('내부망 (같은 공유기)'), icon: Icon(Icons.lan)),
              ButtonSegment(value: 1, label: Text('외부망 중계'), icon: Icon(Icons.cloud)),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
          const SizedBox(height: 16),
          if (_tab == 0) _lanTab() else _cloudTab(),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_error, style: const TextStyle(color: Colors.red)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기')),
        FilledButton(onPressed: _busy ? null : _connect, child: Text(_busy ? '연결 중…' : '연결')),
      ],
    );
  }

  Widget _lanTab() {
    final servers = _found?.where((d) => d.isServer).toList() ?? [];
    final locatorCount = _found?.where((d) => !d.isServer).length ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('같은 네트워크의 서버 카드를 찾습니다 (UDP 40010).')),
        OutlinedButton.icon(
          onPressed: _scanning ? null : _scan,
          icon: _scanning
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.search),
          label: const Text('검색'),
        ),
      ]),
      const SizedBox(height: 8),
      Container(
        constraints: const BoxConstraints(maxHeight: 160),
        decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(6)),
        child: _found == null
            ? const Padding(padding: EdgeInsets.all(12), child: Text('검색 중…'))
            : servers.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_found!.isEmpty
                        ? '찾은 장비가 없습니다. PC가 LocationX와 같은 공유기에 연결돼 있는지 확인하세요.'
                        : '서버 카드가 없습니다 (로케이터 카드 $locatorCount대만 응답).'))
                : ListView(shrinkWrap: true, children: [
                    for (final d in servers)
                      ListTile(
                        dense: true,
                        leading: Icon(Icons.dns, color: _serverCtl.text == d.ip ? Colors.blue : null),
                        title: Text('${d.name}  ${d.ip}'),
                        subtitle: Text('서버 카드 ${d.version} · MQTT ${d.mqttHost}:${d.mqttPort}'),
                        selected: _serverCtl.text == d.ip,
                        onTap: () => _select(d),
                      ),
                  ]),
      ),
      if (locatorCount > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('로케이터 카드 $locatorCount대 응답', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _serverCtl,
            decoration: const InputDecoration(labelText: '서버 카드 IP', isDense: true, border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _brokerCtl,
            decoration: const InputDecoration(
                labelText: 'MQTT 브로커 (비우면 서버 카드)', isDense: true, border: OutlineInputBorder()),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Text('연결하면 서버 카드에서 토픽 이름·로케이터 좌표·외부망 정보를 자동으로 읽습니다.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
    ]);
  }

  Widget _cloudTab() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('서버 카드가 외부 브로커로 중계하는 위치를 받습니다 (LAN 밖에서 사용).'),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: _cloudHostCtl,
              decoration: const InputDecoration(labelText: '외부 브로커 주소', isDense: true, border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _cloudPortCtl,
              decoration: const InputDecoration(labelText: '포트', isDense: true, border: OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _siteCtl,
          decoration: const InputDecoration(labelText: 'siteId (외부 토픽 이름)', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Text('내부망으로 한 번 연결하면 서버 카드의 외부망 설정(브로커·siteId)이 자동으로 채워집니다.\n'
            '외부망은 위치가 토픽별 최대 10 Hz로 줄어들어 드론 제어에는 내부망을 권장합니다.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      ]);
}
