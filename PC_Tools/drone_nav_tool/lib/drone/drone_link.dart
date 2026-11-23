import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../mavlink/mavlink.dart';

/// 펌웨어 control.ino의 비행 모드 번호.
enum FlightMode {
  raw('RAW'),
  acro('ACRO'),
  stab('STAB'),
  althold('ALTHOLD'),
  auto('AUTO');

  final String label;
  const FlightMode(this.label);
}

/// 드론과의 MAVLink UDP 링크 + 텔레메트리 상태.
/// 드론은 14550으로 보내므로 PC도 14550에 바인딩한다 (QGroundControl과 동시 사용 불가).
class DroneLink extends ChangeNotifier {
  static const port = 14550;
  static const linkTimeout = Duration(seconds: 3);

  RawDatagramSocket? _socket;
  final _parser = MavParser();
  final _enc = MavEncoder();
  Timer? _heartbeatTimer;
  Timer? _uiTimer;
  bool _dirty = false;

  /// 드론 주소. 드론은 공유기 망에서 하트비트를 브로드캐스트하므로 첫 하트비트의 보낸 쪽 주소로
  /// 자동으로 정해진다. 브로드캐스트가 막힌 망에서는 [setManualAddress]로 지정한다.
  InternetAddress? droneAddress;
  String bindError = '';

  // 텔레메트리
  DateTime? lastHeartbeat;
  bool armed = false;
  FlightMode? mode;
  bool? landed;
  double roll = 0, pitch = 0, yaw = 0; // deg, FRD
  double accX = 0, accY = 0, accZ = 0; // g, FRD
  double? batteryV;
  double? tofM; // null = 무효/없음
  bool tofPresent = false;
  double? loopRate;
  double? altitude; // 펌웨어 고도 추정 (m), null = 무효
  double climbRate = 0; // m/s
  double? altitudeTarget; // ALTHOLD 목표 (m), null = ALTHOLD 아님
  double thrust = 0; // 0..1

  /// 모터 출력 0..1, 펌웨어 motors[] 순서: 0=RL 1=RR 2=FR 3=FL
  List<double> motors = const [0, 0, 0, 0];

  /// 이륙 후 PC가 유지하는 목표 고도. 비행 중 10 Hz로 보내 펌웨어의 GCS 끊김 감시(1초)를 만족시킨다.
  double? commandedAltitude;
  Timer? _setpointTimer;

  bool get flying => armed && mode == FlightMode.althold;

  /// 수동 스로틀 0..1 (STAB 모드). null이면 보내지 않는다. 켜져 있는 동안 20 Hz로 MANUAL_CONTROL을 보내며,
  /// 끊기면 펌웨어 RC loss 안전장치(SF_RC_LOSS_TIME, 1초)가 천천히 내린다.
  double? manualThrottle;
  Timer? _manualTimer;

  /// 위치 제어기의 기울기 명령 (-1..1, 펌웨어 CTL_TILT_MAX 비율). ALTHOLD에서 스로틀은 무시된다.
  void sendTilt(double roll, double pitch) => _send(_enc.manualControl(roll: roll, pitch: pitch));

  void setManualThrottle(double? value) {
    manualThrottle = value?.clamp(0.0, 1.0);
    if (manualThrottle == null) {
      _manualTimer?.cancel();
      _manualTimer = null;
    } else {
      _manualTimer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
        final v = manualThrottle;
        if (v != null) _send(_enc.manualControl(throttle: v));
      });
    }
    _dirty = true;
  }
  int _msgCount = 0;
  double msgRate = 0;
  DateTime _rateWindow = DateTime.now();

  // 콘솔
  final _console = StreamController<String>.broadcast();
  Stream<String> get consoleStream => _console.stream;
  final StringBuffer _consoleText = StringBuffer();
  String get consoleText => _consoleText.toString();

  // 파라미터
  final SplayTreeMap<String, double> params = SplayTreeMap();
  int paramCount = 0;

  // 명령 응답
  String lastAck = '';

  /// 펌웨어가 마지막으로 출력한 한 줄 (시동 해제 이유 등) — CLI 도움말 출력은 제외
  String lastMessage = '';
  DateTime? lastMessageTime;
  String _lineBuf = '';

  bool get connected =>
      lastHeartbeat != null && DateTime.now().difference(lastHeartbeat!) < linkTimeout;

  Future<void> start() async {
    if (_heartbeatTimer != null) return;
    await _bind();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_socket == null) {
        _bind(); // 닫힌 소켓은 다시 연다
        return;
      }
      // 드론이 안 보일 때는 보내지 않는다: 재부팅 중인 드론이 ICMP port unreachable로
      // 응답하면 Windows UDP 소켓에 WSAECONNRESET이 생긴다. 드론은 스스로 브로드캐스트한다.
      if (connected || _manualAddress) _send(_enc.heartbeat());
    });
    _uiTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now();
      final dt = now.difference(_rateWindow).inMilliseconds;
      if (dt >= 1000) {
        msgRate = _msgCount * 1000 / dt;
        _msgCount = 0;
        _rateWindow = now;
        _dirty = true; // 연결 끊김 표시 갱신
      }
      if (_dirty) {
        _dirty = false;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _setpointTimer?.cancel();
    _manualTimer?.cancel();
    _uiTimer?.cancel();
    _socket?.close();
    _console.close();
    super.dispose();
  }

  bool _binding = false;

  // 진단: 소켓 상태와 아무 곳에서나 받은 UDP 패킷
  bool get socketOpen => _socket != null;
  int rxPackets = 0;
  String lastRxFrom = '';
  DateTime? lastRxTime;

  Future<void> _bind() async {
    if (_binding) return;
    _binding = true;
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
      s.broadcastEnabled = true;
      s.listen(
        (ev) => _onSocket(s, ev),
        onError: (Object e) {}, // WSAECONNRESET 등 — 소켓은 계속 쓴다
        onDone: () {
          if (identical(_socket, s)) _socket = null;
        },
      );
      _socket = s;
      bindError = '';
    } catch (e) {
      bindError = 'UDP $port 포트를 열 수 없음 (QGroundControl 등 다른 프로그램이 사용 중?): $e';
    }
    _binding = false;
    _dirty = true;
  }

  bool _manualAddress = false;

  /// 빈 문자열이면 자동 검색으로 되돌린다.
  void setManualAddress(String ip) {
    droneAddress = InternetAddress.tryParse(ip.trim());
    _manualAddress = droneAddress != null;
    _send(_enc.heartbeat());
    notifyListeners();
  }

  void _send(List<int> bytes) {
    final a = droneAddress;
    if (a == null) return;
    try {
      _socket?.send(bytes, a, port);
    } catch (_) {}
  }

  void _onSocket(RawDatagramSocket s, RawSocketEvent ev) {
    if (ev == RawSocketEvent.closed) {
      if (identical(_socket, s)) _socket = null;
      return;
    }
    if (ev != RawSocketEvent.read) return;
    Datagram? dg;
    try {
      dg = s.receive();
    } catch (_) {
      return; // Windows: 이전 송신의 ICMP 오류가 여기서 올라온다
    }
    if (dg == null) return;
    rxPackets++;
    lastRxFrom = '${dg.address.address}:${dg.port}';
    lastRxTime = DateTime.now();
    _dirty = true;
    for (final m in _parser.feed(dg.data)) {
      if (m.msgId == MavId.heartbeat && m.u8(4) != 6) {
        final first = !connected;
        droneAddress = dg.address; // GCS(type 6)가 아닌 하트비트 = 드론
        _handle(m);
        if (first) {
          _send(_enc.heartbeat()); // 바로 응답해 드론이 텔레메트리를 시작하게
          if (params.isEmpty) Future.delayed(const Duration(seconds: 1), requestParams);
        }
        continue;
      }
      _handle(m);
    }
  }

  void _handle(MavMessage m) {
    _msgCount++;
    _dirty = true;
    switch (m.msgId) {
      case MavId.heartbeat:
        if (m.u8(4) == 6) return; // 다른 GCS
        lastHeartbeat = DateTime.now();
        armed = (m.u8(6) & 0x80) != 0;
        final mi = m.u32(0);
        mode = mi < FlightMode.values.length ? FlightMode.values[mi] : null;
      case MavId.extendedSysState:
        landed = m.u8(1) == 1; // MAV_LANDED_STATE_ON_GROUND
      case MavId.sysStatus:
        final mv = m.u16(14);
        batteryV = mv == 0xffff ? null : mv / 1000.0;
      case MavId.attitudeQuaternion:
        final w = m.f32(4), x = m.f32(8), y = m.f32(12), z = m.f32(16);
        roll = _deg(math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)));
        pitch = _deg(math.asin((2 * (w * y - z * x)).clamp(-1.0, 1.0)));
        yaw = _deg(math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)));
      case MavId.scaledImu:
        accX = m.i16(4) / 1000;
        accY = m.i16(6) / 1000;
        accZ = m.i16(8) / 1000;
      case MavId.actuatorControlTarget:
        motors = [for (var i = 0; i < 4; i++) m.f32(8 + i * 4)];
      case MavId.distanceSensor:
        tofPresent = true;
        tofM = m.u8(38) == 1 ? null : m.u16(8) / 100.0;
      case MavId.namedValueFloat:
        final v = m.f32(4);
        switch (m.str(8, 10)) {
          case 'loop_rate':
            loopRate = v;
          case 'alt':
            altitude = v.isNaN ? null : v;
          case 'climb':
            climbRate = v;
          case 'alt_tgt':
            altitudeTarget = v.isNaN ? null : v;
          case 'thrust':
            thrust = v;
        }
      case MavId.serialControl:
        final n = m.u8(8);
        final text = m.str(9, n > 70 ? 70 : n);
        _consoleText.write(text);
        _lineBuf += text;
        final lines = _lineBuf.split('\n');
        _lineBuf = lines.removeLast();
        for (final l in lines.map((e) => e.trim()).where((e) => e.isNotEmpty && !e.startsWith('>'))) {
          lastMessage = l;
          lastMessageTime = DateTime.now();
        }
        if (_consoleText.length > 60000) {
          final s = _consoleText.toString();
          _consoleText
            ..clear()
            ..write(s.substring(s.length - 40000));
        }
        _console.add(text);
      case MavId.paramValue:
        params[m.str(8, 16)] = m.f32(0);
        paramCount = m.u16(4);
      case MavId.commandAck:
        lastAck = 'cmd ${m.u16(0)}: ${m.u8(2) == 0 ? '수락' : '거부(${m.u8(2)})'}';
      case MavId.statusText:
        final t = '${m.str(1, 50)}\n';
        _consoleText.write(t);
        _console.add(t);
    }
  }

  static double _deg(double r) => r * 180 / math.pi;

  // ---- 명령 ----

  void sendCli(String command) {
    _send(_enc.serialControl(command));
  }

  void arm() => _send(_enc.commandLong(MavCmd.componentArmDisarm, params: [1]));

  void disarm() => _send(_enc.commandLong(MavCmd.componentArmDisarm, params: [0]));

  /// 비상정지: 시동 해제를 여러 번 보낸다 (UDP 유실 대비).
  void emergencyStop() {
    if (manualThrottle != null) setManualThrottle(0);
    for (var i = 0; i < 5; i++) {
      Future.delayed(Duration(milliseconds: i * 30), disarm);
    }
  }

  /// 이륙: 펌웨어가 ALTHOLD로 목표 높이까지 상승한다 (시동 상태여야 함).
  void takeoff(double height) {
    setManualThrottle(null); // 고도 유지가 추력을 맡는다 (펌웨어는 ALTHOLD에서 RC loss를 보지 않음)
    commandedAltitude = height;
    _send(_enc.commandLong(MavCmd.navTakeoff, params: [0, 0, 0, 0, 0, 0, height]));
    _setpointTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) => _streamSetpoint());
  }

  /// 착륙: 펌웨어가 천천히 내려가 착지를 감지하면 시동을 끈다.
  void land() {
    commandedAltitude = null;
    _send(_enc.commandLong(MavCmd.navLand));
  }

  void setAltitude(double height) {
    if (!flying) return;
    commandedAltitude = height;
    _send(_enc.setAltitude(height));
  }

  void _streamSetpoint() {
    final h = commandedAltitude;
    if (!armed) {
      // 착지·시동 해제 후 스트림 종료
      _setpointTimer?.cancel();
      _setpointTimer = null;
      commandedAltitude = null;
      return;
    }
    if (h != null && mode == FlightMode.althold) _send(_enc.setAltitude(h));
  }

  void setMode(FlightMode m) =>
      _send(_enc.commandLong(MavCmd.doSetMode, params: [0, m.index.toDouble()]));

  void requestParams() {
    params.clear();
    paramCount = 0;
    _send(_enc.paramRequestList());
    notifyListeners();
  }

  void setParam(String name, double value) => _send(_enc.paramSet(name, value));

  void clearConsole() {
    _consoleText.clear();
    notifyListeners();
  }
}
