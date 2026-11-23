import 'dart:math' as math;

import 'package:drone_nav_tool/control/position_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 1, 1);

  PositionController at(Offset p) {
    final c = PositionController()..latency = 0;
    c.measure(p, t0);
    return c;
  }

  test('target ahead of the nose -> pitch forward (positive), no roll', () {
    final c = at(Offset.zero);
    final cmd = c.update(const Offset(1, 0), 0, 0.05, t0); // 기수 +x, 목표 +x
    expect(cmd.pitch, greaterThan(0));
    expect(cmd.roll.abs(), lessThan(1e-9));
  });

  test('target to the right of the nose -> roll right (positive)', () {
    final c = at(Offset.zero);
    final cmd = c.update(const Offset(1, 0), math.pi / 2, 0.05, t0); // 기수 +y, 목표 +x = 오른쪽
    expect(cmd.roll, greaterThan(0));
    expect(cmd.pitch.abs(), lessThan(1e-9));
  });

  test('target behind -> pitch back, target left -> roll left', () {
    final c = at(Offset.zero);
    expect(c.update(const Offset(-1, 0), 0, 0.05, t0).pitch, lessThan(0));
    final c2 = at(Offset.zero);
    expect(c2.update(const Offset(0, 1), 0, 0.05, t0).roll, lessThan(0)); // 기수 +x, 목표 +y = 왼쪽
  });

  test('tilt is limited to tiltMaxDeg', () {
    final c = at(Offset.zero)
      ..tiltMaxDeg = 8
      ..kVel = 100; // 큰 가속 요구로 한계까지 (기본 게인은 vMax로 먼저 제한됨)
    final cmd = c.update(const Offset(50, 0), 0, 0.05, t0);
    expect(cmd.pitch * 180 / math.pi, closeTo(8, 1e-6));
  });

  test('moving toward the target faster than vMax brakes', () {
    final c = PositionController()..latency = 0;
    // 0.5 m/s로 +x 이동 중인 측정
    for (var i = 0; i <= 20; i++) {
      c.measure(Offset(i * 0.02, 0), t0.add(Duration(milliseconds: i * 40)));
    }
    expect(c.vel.dx, greaterThan(0.3));
    final cmd = c.update(const Offset(1.0, 0), 0, 0.05, t0.add(const Duration(milliseconds: 800)));
    expect(cmd.pitch, lessThan(0)); // vMax 0.3보다 빠르니 감속 (뒤로 기울임)
  });
}
