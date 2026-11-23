import 'dart:math' as math;
import 'dart:ui';

/// AoA 위치(약 25 Hz, σ 0.1~0.2 m)로 수평 위치를 잡는 제어기. 모든 벡터는 지도 좌표(m, x 오른쪽, y 위).
///
/// 위치 → 알파-베타 필터(위치·속도) → 지연 보상 예측 → 목표 속도(P, vMax 제한)
/// → 가속도(속도 P + 위치 I) → 기울기(atan(a/g), tiltMax 제한) → 기체 앞/오른쪽 성분.
class PositionController {
  // 튜닝값
  double kPos = 0.8; // 위치 오차 → 목표 속도 (1/s)
  double kVel = 1.8; // 속도 오차 → 가속도 (1/s)
  double kInt = 0.15; // 위치 오차 적분 → 가속도 (1/s²), 무게중심·트림 치우침 보상
  double vMax = 0.3; // m/s
  double tiltMaxDeg = 8;
  double latency = 0.15; // AoA 지연 보상 (s)
  double alpha = 0.35, beta = 0.06; // 필터 계수

  static const g = 9.81;
  static const _intZone = 0.5; // 이 거리 안에서만 적분 (이동 중 누적 방지), m
  static const _intMaxAccel = 0.6; // 적분항 한계, m/s²

  Offset? pos; // 필터된 위치
  Offset vel = Offset.zero;
  DateTime? _measTime;
  Offset _integral = Offset.zero;

  /// 마지막 계산 결과 (화면 표시용)
  Offset accel = Offset.zero; // 지도 좌표 가속도 명령
  double rollDeg = 0, pitchDeg = 0; // 기체 명령 (pitch + = 기수 내림 = 앞으로)

  void reset() {
    pos = null;
    vel = Offset.zero;
    _measTime = null;
    _integral = Offset.zero;
    accel = Offset.zero;
    rollDeg = pitchDeg = 0;
  }

  void resetIntegral() => _integral = Offset.zero;

  void measure(Offset z, DateTime t) {
    final p = pos;
    final last = _measTime;
    if (p == null || last == null) {
      pos = z;
      vel = Offset.zero;
      _measTime = t;
      return;
    }
    final dt = t.difference(last).inMicroseconds / 1e6;
    if (dt <= 0) return;
    if (dt > 0.5) {
      // 오래 끊겼다가 다시 들어옴: 다시 시작
      pos = z;
      vel = Offset.zero;
      _measTime = t;
      return;
    }
    final predicted = p + vel * dt;
    final r = z - predicted;
    pos = predicted + r * alpha;
    vel = vel + r * (beta / dt);
    _measTime = t;
  }

  /// 지연 보상한 현재 위치 추정
  Offset? predict(DateTime now) {
    final p = pos, t = _measTime;
    if (p == null || t == null) return null;
    final age = now.difference(t).inMicroseconds / 1e6;
    return p + vel * (age + latency);
  }

  /// [heading]: 기수가 향한 지도 방향 (rad, +x에서 반시계). 반환: 기체 roll/pitch (rad).
  ({double roll, double pitch}) update(Offset target, double heading, double dt, DateTime now) {
    final p = predict(now);
    if (p == null) return (roll: 0.0, pitch: 0.0);
    final err = target - p;

    var vDes = err * kPos;
    if (vDes.distance > vMax) vDes = vDes / vDes.distance * vMax;

    if (err.distance < _intZone) {
      _integral += err * dt;
      final lim = _intMaxAccel / math.max(kInt, 1e-6);
      if (_integral.distance > lim) _integral = _integral / _integral.distance * lim;
    }

    var a = (vDes - vel) * kVel + _integral * kInt;
    final aMax = g * math.tan(tiltMaxDeg * math.pi / 180);
    if (a.distance > aMax) a = a / a.distance * aMax;
    accel = a;

    // 지도 → 기체: 앞 = (cosψ, sinψ), 오른쪽 = (sinψ, -cosψ)
    final fwd = Offset(math.cos(heading), math.sin(heading));
    final right = Offset(math.sin(heading), -math.cos(heading));
    final aF = a.dx * fwd.dx + a.dy * fwd.dy;
    final aR = a.dx * right.dx + a.dy * right.dy;
    final pitch = math.atan(aF / g); // + = 기수 내림 → 앞으로 가속
    final roll = math.atan(aR / g); // + = 오른쪽 내림 → 오른쪽으로 가속
    rollDeg = roll * 180 / math.pi;
    pitchDeg = pitch * 180 / math.pi;
    return (roll: roll, pitch: pitch);
  }
}
