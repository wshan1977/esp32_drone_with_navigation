import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'locationx_api.dart';

enum AoaStatus { disconnected, connecting, connected, error }

enum AoaSource { lan, cloud }

/// 태그 하나의 최신 위치와 궤적.
class TagTrack {
  final String id;
  double x = 0, y = 0, z = 0; // m
  double xStd = 0, yStd = 0, zStd = 0; // m
  DateTime last = DateTime.now();
  final Queue<DateTime> _recent = Queue();
  final List<Offset> trail = [];

  TagTrack(this.id);

  static const maxTrail = 300;

  Offset get xy => Offset(x, y);
  double get stdev => math.sqrt(xStd * xStd + yStd * yStd);
  Duration get age => DateTime.now().difference(last);

  /// 최근 5초 수신율 (Hz)
  double get rateHz {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 5));
    while (_recent.isNotEmpty && _recent.first.isBefore(cutoff)) {
      _recent.removeFirst();
    }
    return _recent.length / 5.0;
  }

  void _update(Map<String, dynamic> j) {
    x = (j['x'] as num).toDouble();
    y = (j['y'] as num).toDouble();
    z = (j['z'] as num?)?.toDouble() ?? 0;
    xStd = (j['x_stdev'] as num?)?.toDouble() ?? 0;
    yStd = (j['y_stdev'] as num?)?.toDouble() ?? 0;
    zStd = (j['z_stdev'] as num?)?.toDouble() ?? 0;
    last = DateTime.now();
    _recent.addLast(last);
    if (trail.isEmpty || (trail.last - xy).distance >= 0.02) {
      trail.add(xy);
      if (trail.length > maxTrail) trail.removeAt(0);
    }
  }
}

/// LocationX 위치 MQTT 구독 (SDK docs/02_data_interface.md).
/// - 내부망: 서버 카드 브로커, `<root>/aoa/position/<positioningId>/<tagId>`
/// - 외부망: 외부 브로커, `locationx/<siteId>/<root>/aoa/position/...` + `placements`(로케이터, retained)
class AoaClient extends ChangeNotifier {
  MqttServerClient? _client;
  StreamSubscription? _sub;
  Timer? _uiTimer;
  bool _dirty = false;

  AoaStatus status = AoaStatus.disconnected;
  AoaSource source = AoaSource.lan;
  String error = '';
  String host = '';
  int port = 1883;
  String topicRoot = 'controlbit';
  String siteId = '';

  /// 로케이터 좌표 (내부망: 서버 카드 HTTP, 외부망: placements 토픽)
  List<LxLocator> locators = [];

  final SplayTreeMap<String, TagTrack> tags = SplayTreeMap();

  AoaClient() {
    _uiTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_dirty) {
        _dirty = false;
        notifyListeners();
      }
    });
  }

  String get _prefix => source == AoaSource.cloud ? 'locationx/$siteId/' : '';

  /// 로케이터가 둘러싼 사각형 (m). 2개 미만이면 null.
  Rect? get locatorBounds {
    if (locators.length < 2) return null;
    var r = Rect.fromPoints(Offset(locators.first.x, locators.first.y), Offset(locators.first.x, locators.first.y));
    for (final l in locators) {
      r = r.expandToInclude(Rect.fromPoints(Offset(l.x, l.y), Offset(l.x, l.y)));
    }
    return r;
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    disconnect();
    super.dispose();
  }

  Future<void> connectLan(String brokerHost,
      {int brokerPort = 1883, String root = 'controlbit', List<LxLocator> locators = const []}) {
    source = AoaSource.lan;
    topicRoot = root.isEmpty ? 'controlbit' : root;
    this.locators = List.of(locators);
    return _connect(brokerHost, brokerPort, '$topicRoot/aoa/position/#');
  }

  Future<void> connectCloud(String brokerHost, {int brokerPort = 1883, required String site}) {
    source = AoaSource.cloud;
    siteId = site.trim();
    locators = [];
    return _connect(brokerHost, brokerPort, 'locationx/$siteId/#');
  }

  Future<void> _connect(String newHost, int newPort, String filter) async {
    disconnect();
    tags.clear();
    host = newHost.trim();
    port = newPort;
    status = AoaStatus.connecting;
    error = '';
    notifyListeners();

    final client = MqttServerClient.withPort(
        host, 'drone_nav_${DateTime.now().millisecondsSinceEpoch % 100000}', port)
      ..keepAlivePeriod = 20
      ..autoReconnect = true
      ..logging(on: false)
      ..onDisconnected = () {
        if (status == AoaStatus.connected) status = AoaStatus.disconnected;
        _dirty = true;
      }
      ..onAutoReconnected = () {
        status = AoaStatus.connected;
        _dirty = true;
      };
    client.connectionMessage = MqttConnectMessage().startClean();
    _client = client;
    try {
      await client.connect();
    } catch (e) {
      error = '$e';
    }
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      status = AoaStatus.error;
      if (error.isEmpty) error = '연결 실패: ${client.connectionStatus}';
      client.autoReconnect = false;
      client.disconnect();
      _client = null;
      notifyListeners();
      return;
    }
    status = AoaStatus.connected;
    client.subscribe(filter, MqttQos.atMostOnce);
    _sub = client.updates?.listen(_onMessages);
    notifyListeners();
  }

  void disconnect() {
    _sub?.cancel();
    _sub = null;
    _client?.autoReconnect = false;
    _client?.disconnect();
    _client = null;
    if (status != AoaStatus.error) status = AoaStatus.disconnected;
    notifyListeners();
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> msgs) {
    for (final m in msgs) {
      final pub = m.payload as MqttPublishMessage;
      var topic = m.topic;
      if (_prefix.isNotEmpty) {
        if (!topic.startsWith(_prefix)) continue;
        topic = topic.substring(_prefix.length);
      }
      _handle(topic, utf8.decode(pub.payload.message, allowMalformed: true));
    }
  }

  void _handle(String topic, String payload) {
    dynamic j;
    try {
      j = jsonDecode(payload);
    } catch (_) {
      return;
    }
    if (j is! Map<String, dynamic>) return;

    if (topic == 'placements') {
      locators = [
        if (j['locators'] is List)
          for (final l in j['locators'] as List)
            if (LxLocator.fromJson(l) case final loc?) loc,
      ];
      _dirty = true;
      return;
    }
    if (topic == 'agent') {
      if (j['root'] is String) topicRoot = j['root'] as String;
      _dirty = true;
      return;
    }

    final parts = topic.split('/');
    final i = parts.indexOf('position');
    if (i < 1 || parts[i - 1] != 'aoa' || parts.length < i + 3) return;
    if (j['x'] is! num || j['y'] is! num) return;
    // SDK 권장 무효값 제거 (docs/02_data_interface.md)
    final xs = (j['x_stdev'] as num?)?.toDouble() ?? 0;
    final ys = (j['y_stdev'] as num?)?.toDouble() ?? 0;
    final sd = math.sqrt(xs * xs + ys * ys);
    final allZero = j['x'] == 0 && j['y'] == 0 && (j['z'] ?? 0) == 0;
    if (sd > 1000 || (allZero && sd > 100)) return;

    tags.putIfAbsent(parts.last, () => TagTrack(parts.last))._update(j);
    _dirty = true;
  }

  void clearTrails() {
    for (final t in tags.values) {
      t.trail.clear();
    }
    notifyListeners();
  }
}
