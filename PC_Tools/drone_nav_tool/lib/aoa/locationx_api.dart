import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// UDP 40010 검색 응답 1건 (SDK docs/03_http_api.md §1). `cap`이 없으면 서버 카드.
class LxDevice {
  final String name;
  final String ip;
  final String version;
  final String mqttHost;
  final int mqttPort;
  final bool isServer;

  LxDevice({
    required this.name,
    required this.ip,
    required this.version,
    required this.mqttHost,
    required this.mqttPort,
    required this.isServer,
  });
}

/// 서버 카드 HTTP(:8080)에서 읽은 설치 정보.
class LxServerInfo {
  final String topicRoot;
  final String positioningId;
  final List<LxLocator> locators;
  final String cloudHost;
  final int cloudPort;
  final String siteId;
  final bool cloudEnabled;

  LxServerInfo({
    required this.topicRoot,
    required this.positioningId,
    required this.locators,
    required this.cloudHost,
    required this.cloudPort,
    required this.siteId,
    required this.cloudEnabled,
  });
}

class LxLocator {
  final String id;
  final double x, y, z;
  LxLocator(this.id, this.x, this.y, this.z);

  String get shortId => id.length >= 4 ? id.substring(id.length - 4) : id;

  static LxLocator? fromJson(dynamic j) {
    if (j is! Map || j['coordinate'] is! Map) return null;
    final c = j['coordinate'] as Map;
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0;
    return LxLocator(j['id']?.toString() ?? '', d(c['x']), d(c['y']), d(c['z']));
  }
}

class LocationXApi {
  static const discoverPort = 40010;
  static const httpPort = 8080;

  /// LAN의 LocationX 카드 검색. 서브넷별 브로드캐스트를 3번 보낸다 (UDP 유실 대비).
  static Future<List<LxDevice>> discover({Duration window = const Duration(seconds: 3)}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final found = <String, LxDevice>{};
    socket.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      Datagram? dg;
      while ((dg = socket.receive()) != null) {
        try {
          final j = jsonDecode(utf8.decode(dg!.data, allowMalformed: true));
          if (j is! Map || j['type'] != 'DISCOVER_RESPONSE') continue;
          final ip = j['ip']?.toString() ?? dg.address.address;
          final mqtt = j['mqtt'] is Map ? j['mqtt'] as Map : const {};
          found[ip] = LxDevice(
            name: j['device']?.toString() ?? '',
            ip: ip,
            version: j['ver']?.toString() ?? '',
            mqttHost: mqtt['host']?.toString() ?? '',
            mqttPort: (mqtt['port'] as num?)?.toInt() ?? 1883,
            isServer: !j.containsKey('cap'),
          );
        } catch (_) {}
      }
    });

    final targets = <String>{'255.255.255.255'};
    for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in iface.addresses) {
        final p = a.address.split('.');
        if (p.length == 4 && p[0] != '127') targets.add('${p[0]}.${p[1]}.${p[2]}.255'); // /24 가정
      }
    }
    final payload = utf8.encode(jsonEncode({'type': 'DISCOVER'}));
    for (var i = 0; i < 3; i++) {
      for (final t in targets) {
        try {
          socket.send(payload, InternetAddress(t), discoverPort);
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await Future.delayed(window - const Duration(milliseconds: 1500));
    socket.close();
    final list = found.values.toList()
      ..sort((a, b) => a.isServer == b.isServer ? a.name.compareTo(b.name) : (a.isServer ? -1 : 1));
    return list;
  }

  static Future<Map<String, dynamic>> _get(String host, String path) async {
    final res = await http
        .get(Uri.parse('http://$host:$httpPort$path'))
        .timeout(const Duration(seconds: 5));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (j['ok'] != true) throw Exception(j['error'] ?? 'HTTP ${res.statusCode}');
    return j;
  }

  /// 서버 카드에서 토픽 루트·로케이터 좌표·외부망 설정을 읽는다.
  /// /api/topic(v2.8.0+), /api/cloud(v2.2.0+)가 없는 구버전이면 기본값을 쓴다.
  static Future<LxServerInfo> fetchServerInfo(String host) async {
    final pos = await _get(host, '/api/positioning');
    final p = pos['positioning'] is Map ? pos['positioning'] as Map : const {};
    final locators = <LxLocator>[
      if (p['locators'] is List)
        for (final l in p['locators'] as List)
          if (LxLocator.fromJson(l) case final loc?) loc,
    ];

    var root = 'controlbit';
    try {
      root = (await _get(host, '/api/topic'))['root']?.toString() ?? root;
    } catch (_) {}

    Map applied = const {};
    try {
      final c = await _get(host, '/api/cloud');
      if (c['applied'] is Map) applied = c['applied'] as Map;
    } catch (_) {}

    return LxServerInfo(
      topicRoot: root,
      positioningId: p['id']?.toString() ?? '',
      locators: locators,
      cloudHost: applied['broker_host']?.toString() ?? '',
      cloudPort: (applied['broker_port'] as num?)?.toInt() ?? 1883,
      siteId: applied['site_id']?.toString() ?? '',
      cloudEnabled: applied['enabled'] == true,
    );
  }
}
