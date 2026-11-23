import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../aoa/aoa_client.dart';
import '../app/settings.dart';
import '../drone/drone_link.dart';
import 'position_controller.dart';

enum NavState { idle, hold, goto }

/// 수평 위치 비행: 이륙 후 자동 제자리 호버링(위치 유지), 지도 목표로 이동.
/// 펌웨어 ALTHOLD가 높이를 잡고, 여기서는 20 Hz로 기울기(MANUAL_CONTROL roll/pitch)를 보낸다.
class NavController extends ChangeNotifier {
  final DroneLink link;
  final AoaClient aoa;
  final AppSettings settings;
  final PositionController pc = PositionController();

  static const _rate = Duration(milliseconds: 50);
  static const engageHeight = 0.12; // 이 높이 이상 뜨면 자동으로 위치 유지 시작, m
  static const arriveRadius = 0.15; // 목표 도착 판정, m
  static const aoaStale = Duration(milliseconds: 300);
  static const aoaLostLand = Duration(seconds: 2);
  static const maxStdev = 0.4; // AoA 품질 한계, m

  NavState state = NavState.idle;
  Offset? target; // 현재 제어 목표 (지도 m)
  Offset? _takeoffPoint;
  double? _yawAtTakeoff; // 이륙 시 펌웨어 yaw (deg, FRD)
  bool _autoHold = false; // 이륙 직후 위치 유지 자동 시작 대기
  DateTime? _badSince;
  DateTime? _lastMeas;
  String status = '';
  Rect? geofence;

  Timer? _timer;
  IOSink? _log;
  String logPath = '';

  NavController(this.link, this.aoa, this.settings) {
    _timer = Timer.periodic(_rate, (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _closeLog();
    super.dispose();
  }

  TagTrack? get _tag => aoa.tags[settings.droneTagId];

  /// 기수가 향한 지도 방향 (rad). 이륙 시 설정 방향 + 그 뒤의 yaw 변화 (FRD yaw는 시계 방향 +).
  double get heading {
    final yaw0 = _yawAtTakeoff ?? link.yaw;
    return (settings.noseHeadingDeg - (link.yaw - yaw0)) * math.pi / 180;
  }

  /// [이륙] 직전에 호출: 이륙 지점과 방향 기준을 기억한다.
  void prepareTakeoff() {
    final t = _tag;
    _takeoffPoint = (t != null && t.age < aoaStale) ? t.xy : null;
    _yawAtTakeoff = link.yaw;
    _autoHold = true;
    pc.reset();
    status = _takeoffPoint == null ? 'AoA 위치 없음: 이륙 후 위치 유지 불가' : '이륙 중… 12cm 이상 뜨면 위치 유지';
    notifyListeners();
  }

  void hold() {
    final p = pc.pos ?? _tag?.xy;
    if (p == null || !link.flying) return;
    target = p;
    state = NavState.hold;
    pc.resetIntegral();
    notifyListeners();
  }

  bool get canGoto => link.flying && state != NavState.idle;

  void goTo(Offset t) {
    if (!canGoto) return;
    target = t;
    state = NavState.goto;
    pc.resetIntegral();
    notifyListeners();
  }

  void _stop(String why) {
    if (state != NavState.idle) status = why;
    state = NavState.idle;
    target = null;
    _autoHold = false;
    _badSince = null;
    pc.reset();
    _closeLog();
    notifyListeners();
  }

  void _tick() {
    if (!link.flying) {
      if (state != NavState.idle || _autoHold && !link.armed) _stop(link.armed ? '' : '착지');
      return;
    }

    final now = DateTime.now();
    final tag = _tag;
    if (tag != null && tag.last != _lastMeas) {
      _lastMeas = tag.last;
      pc.measure(tag.xy, tag.last);
    }

    // 이륙 후 자동 위치 유지
    if (state == NavState.idle) {
      if (_autoHold && (link.altitude ?? 0) > engageHeight && pc.pos != null) {
        target = _takeoffPoint ?? pc.pos;
        state = NavState.hold;
        _autoHold = false;
        status = '위치 유지 시작';
        _openLog();
      } else {
        return; // 아직 위치 제어 안 함 (펌웨어는 수평 유지)
      }
    }

    // AoA 품질 감시
    final bad = tag == null || now.difference(tag.last) > aoaStale || tag.stdev > maxStdev;
    if (bad) {
      _badSince ??= now;
      link.sendTilt(0, 0); // 수평 유지
      if (now.difference(_badSince!) > aoaLostLand) {
        link.land();
        _stop('AoA 위치를 잃어 착륙');
      } else {
        status = 'AoA 품질 저하: 수평 유지';
      }
      notifyListeners();
      return;
    }
    _badSince = null;

    final p = pc.predict(now);
    if (p != null && geofence != null && !geofence!.inflate(0.3).contains(p)) {
      link.sendTilt(0, 0);
      link.land();
      _stop('비행 영역을 벗어나 착륙');
      return;
    }

    final tgt = target!;
    final cmd = pc.update(tgt, heading, _rate.inMicroseconds / 1e6, now);
    final tiltMax = link.params['CTL_TILT_MAX'] ?? (30 * math.pi / 180);
    link.sendTilt(cmd.roll / tiltMax, cmd.pitch / tiltMax);

    final dist = p == null ? double.nan : (tgt - p).distance;
    if (state == NavState.goto && dist < arriveRadius) {
      state = NavState.hold;
      status = '목표 도착, 위치 유지';
    } else {
      status = '${state == NavState.goto ? "이동 중" : "위치 유지"} · 오차 ${dist.toStringAsFixed(2)} m · '
          '명령 앞 ${pc.pitchDeg.toStringAsFixed(1)}° 오른 ${pc.rollDeg.toStringAsFixed(1)}°';
    }
    _logRow(now, tag, p, tgt, dist);
    notifyListeners();
  }

  // ---- CSV 로그 (튜닝용) ----

  void _openLog() {
    try {
      final home = Platform.environment['USERPROFILE'] ?? Directory.current.path;
      final dir = Directory('$home${Platform.pathSeparator}Documents${Platform.pathSeparator}DroneNavTool');
      dir.createSync(recursive: true);
      final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);
      logPath = '${dir.path}${Platform.pathSeparator}flight_$ts.csv';
      _log = File(logPath).openWrite()
        ..writeln('t,aoa_x,aoa_y,aoa_std,est_x,est_y,vx,vy,tgt_x,tgt_y,dist,heading_deg,roll_cmd,pitch_cmd,alt,thrust,batt');
    } catch (_) {
      _log = null;
    }
  }

  DateTime? _logStart;
  void _logRow(DateTime now, TagTrack tag, Offset? p, Offset tgt, double dist) {
    final l = _log;
    if (l == null) return;
    _logStart ??= now;
    String f(num? v, [int d = 3]) => v == null || v.isNaN ? '' : v.toStringAsFixed(d);
    l.writeln([
      f(now.difference(_logStart!).inMilliseconds / 1000),
      f(tag.x), f(tag.y), f(tag.stdev),
      f(p?.dx), f(p?.dy), f(pc.vel.dx), f(pc.vel.dy),
      f(tgt.dx), f(tgt.dy), f(dist),
      f(heading * 180 / math.pi, 1), f(pc.rollDeg, 2), f(pc.pitchDeg, 2),
      f(link.altitude), f(link.thrust), f(link.batteryV, 2),
    ].join(','));
  }

  void _closeLog() {
    _log?.close();
    _log = null;
    _logStart = null;
  }
}
