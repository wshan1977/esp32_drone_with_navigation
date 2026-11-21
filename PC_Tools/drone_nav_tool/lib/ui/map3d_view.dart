import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../aoa/aoa_client.dart';
import '../aoa/locationx_api.dart';

/// 3D 보기: 바닥 격자, 로케이터(천장 높이), 태그(x,y,z), 드론, 목표점.
/// 드래그 = 회전, Shift+드래그 = 이동, 휠 = 확대. 바닥 클릭 = 목표점 (2D와 같은 규칙).
/// 투영은 locationx_install_tool position_live_view.dart의 _Live3dPainter와 같은 방식.
class Map3DView extends StatefulWidget {
  final AoaClient aoa;
  final List<LxLocator> locators;
  final String droneTagId;
  final double? droneHeight; // ToF 높이 (m). 있으면 AoA z 대신 쓴다
  final Offset? target;
  final bool droneSelected;
  final Rect? geofence;
  final VoidCallback onDroneTap;
  final ValueChanged<Offset> onMapTap;

  const Map3DView({
    super.key,
    required this.aoa,
    required this.locators,
    required this.droneTagId,
    required this.droneHeight,
    required this.target,
    required this.droneSelected,
    required this.geofence,
    required this.onDroneTap,
    required this.onMapTap,
  });

  @override
  State<Map3DView> createState() => Map3DViewState();
}

class Map3DViewState extends State<Map3DView> {
  double _yaw = -0.6; // rad
  double _pitch = 0.6; // rad, 0 = 수평에서 봄
  double _scale = 70; // px/m
  Offset _pan = Offset.zero;
  _Projection? _proj;

  void reset() => setState(() {
        _yaw = -0.6;
        _pitch = 0.6;
        _scale = 70;
        _pan = Offset.zero;
      });

  Rect _bounds() {
    Rect? r;
    for (final p in [
      for (final l in widget.locators) Offset(l.x, l.y),
      for (final t in widget.aoa.tags.values) t.xy,
    ]) {
      final pr = Rect.fromCenter(center: p, width: 0.01, height: 0.01);
      r = r == null ? pr : r.expandToInclude(pr);
    }
    return (r ?? const Rect.fromLTWH(0, 0, 4, 4)).inflate(1);
  }

  void _onTap(Offset pos) {
    final proj = _proj;
    if (proj == null) return;
    final d = widget.aoa.tags[widget.droneTagId];
    if (d != null) {
      final z = widget.droneHeight ?? d.z;
      if ((proj.p(d.x, d.y, z) - pos).distance < 24) {
        widget.onDroneTap();
        return;
      }
    }
    final w = proj.floorAt(pos);
    if (w != null) widget.onMapTap(w);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          setState(() => _scale = (_scale * (e.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12)).clamp(10.0, 600.0));
        }
      },
      child: GestureDetector(
        onTapUp: (d) => _onTap(d.localPosition),
        onPanUpdate: (d) => setState(() {
          if (HardwareKeyboard.instance.isShiftPressed) {
            _pan += d.delta;
          } else {
            _yaw += d.delta.dx * 0.008;
            _pitch = (_pitch + d.delta.dy * 0.006).clamp(0.05, math.pi / 2);
          }
        }),
        child: ClipRect(
          child: CustomPaint(
            size: Size.infinite,
            painter: _Map3DPainter(
              view: this,
              bounds: _bounds(),
            ),
          ),
        ),
      ),
    );
  }
}

/// world(m, z-up) ↔ 화면 변환.
class _Projection {
  final Matrix4 m;
  _Projection(this.m);

  Offset p(double x, double y, double z) {
    final s = m.storage;
    final tx = s[0] * x + s[4] * y + s[8] * z + s[12];
    final ty = s[1] * x + s[5] * y + s[9] * z + s[13];
    final tw = s[3] * x + s[7] * y + s[11] * z + s[15];
    return Offset(tx / tw, ty / tw);
  }

  /// 화면 점 → 바닥(z=0) 위 world 좌표. 바닥과 평행한 시선이면 null.
  Offset? floorAt(Offset sp) {
    final s = m.storage;
    // sx*(s3 x + s7 y + s15) = s0 x + s4 y + s12, sy도 같은 꼴 → 2x2 연립
    final a1 = s[0] - sp.dx * s[3], b1 = s[4] - sp.dx * s[7], c1 = sp.dx * s[15] - s[12];
    final a2 = s[1] - sp.dy * s[3], b2 = s[5] - sp.dy * s[7], c2 = sp.dy * s[15] - s[13];
    final det = a1 * b2 - a2 * b1;
    if (det.abs() < 1e-9) return null;
    return Offset((c1 * b2 - c2 * b1) / det, (a1 * c2 - a2 * c1) / det);
  }
}

class _Map3DPainter extends CustomPainter {
  final Map3DViewState view;
  final Rect bounds;

  _Map3DPainter({required this.view, required this.bounds});

  Map3DView get w => view.widget;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF4F6F8));
    final c = bounds.center;
    final m = Matrix4.identity()
      ..translate(size.width / 2 + view._pan.dx, size.height * 0.58 + view._pan.dy)
      ..setEntry(3, 2, -0.0009)
      ..rotateX(math.pi / 2 - view._pitch)
      ..rotateZ(view._yaw)
      ..scale(view._scale, -view._scale, view._scale)
      ..translate(-c.dx, -c.dy, 0);
    final proj = _Projection(m);
    view._proj = proj;
    Offset p(double x, double y, double z) => proj.p(x, y, z);

    // 바닥 격자
    final grid = Paint()
      ..color = const Color(0x22000000)
      ..strokeWidth = 1;
    final x0 = bounds.left.floorToDouble(), x1 = bounds.right.ceilToDouble();
    final y0 = bounds.top.floorToDouble(), y1 = bounds.bottom.ceilToDouble();
    for (var x = x0; x <= x1; x++) {
      canvas.drawLine(p(x, y0, 0), p(x, y1, 0), grid);
    }
    for (var y = y0; y <= y1; y++) {
      canvas.drawLine(p(x0, y, 0), p(x1, y, 0), grid);
    }
    // 축
    canvas.drawLine(p(0, 0, 0), p(1, 0, 0), Paint()
      ..color = Colors.red
      ..strokeWidth = 2.5);
    canvas.drawLine(p(0, 0, 0), p(0, 1, 0), Paint()
      ..color = Colors.green
      ..strokeWidth = 2.5);
    canvas.drawLine(p(0, 0, 0), p(0, 0, 1), Paint()
      ..color = Colors.blue
      ..strokeWidth = 2.5);
    _text(canvas, 'x', p(1.1, 0, 0), const TextStyle(color: Colors.red, fontSize: 11));
    _text(canvas, 'y', p(0, 1.1, 0), const TextStyle(color: Colors.green, fontSize: 11));
    _text(canvas, 'z', p(0, 0, 1.1), const TextStyle(color: Colors.blue, fontSize: 11));

    // 비행 영역
    final g = w.geofence;
    if (g != null) {
      final path = Path()
        ..moveTo(p(g.left, g.top, 0).dx, p(g.left, g.top, 0).dy)
        ..lineTo(p(g.right, g.top, 0).dx, p(g.right, g.top, 0).dy)
        ..lineTo(p(g.right, g.bottom, 0).dx, p(g.right, g.bottom, 0).dy)
        ..lineTo(p(g.left, g.bottom, 0).dx, p(g.left, g.bottom, 0).dy)
        ..close();
      canvas.drawPath(path, Paint()..color = const Color(0x142E7D32));
      canvas.drawPath(path, Paint()
        ..color = const Color(0xFF2E7D32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }

    // 로케이터: 바닥에서 설치 높이까지 기둥 + 상자
    for (final l in w.locators) {
      canvas.drawLine(p(l.x, l.y, 0), p(l.x, l.y, l.z), Paint()
        ..color = const Color(0x55455A64)
        ..strokeWidth = 1);
      final top = p(l.x, l.y, l.z);
      canvas.drawRect(Rect.fromCenter(center: top, width: 14, height: 10), Paint()..color = const Color(0xFF455A64));
      _text(canvas, '${l.shortId} (${l.z.toStringAsFixed(1)}m)', top + const Offset(9, -14),
          const TextStyle(fontSize: 11, color: Color(0xFF455A64), fontWeight: FontWeight.w600));
    }

    // 목표점
    final tg = w.target;
    final drone = w.aoa.tags[w.droneTagId];
    final droneZ = drone == null ? 0.0 : (w.droneHeight ?? drone.z);
    if (tg != null) {
      final tz = droneZ > 0.1 ? droneZ : 1.0; // 목표 높이 표시: 현재 비행 높이 (없으면 1m)
      final orange = Paint()
        ..color = const Color(0xFFD84315)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(p(tg.dx, tg.dy, 0), p(tg.dx, tg.dy, tz), orange..strokeWidth = 1.2);
      _floorCircle(canvas, proj, tg, 0.15, orange..strokeWidth = 2);
      canvas.drawCircle(p(tg.dx, tg.dy, tz), 6, Paint()..color = const Color(0xFFD84315));
      _text(canvas, '목표 (${tg.dx.toStringAsFixed(2)}, ${tg.dy.toStringAsFixed(2)})', p(tg.dx, tg.dy, tz) + const Offset(10, -20),
          const TextStyle(fontSize: 12, color: Color(0xFFD84315), fontWeight: FontWeight.bold));
      if (drone != null) {
        _dashed(canvas, p(drone.x, drone.y, droneZ), p(tg.dx, tg.dy, tz), Paint()
          ..color = const Color(0xFFD84315)
          ..strokeWidth = 1.5);
      }
    }

    // 다른 태그
    for (final t in w.aoa.tags.values) {
      if (t.id == w.droneTagId) continue;
      final col = Colors.blueGrey.withValues(alpha: t.age > const Duration(seconds: 2) ? 0.3 : 0.75);
      canvas.drawLine(p(t.x, t.y, 0), p(t.x, t.y, t.z), Paint()
        ..color = col.withValues(alpha: 0.3)
        ..strokeWidth = 1);
      canvas.drawCircle(p(t.x, t.y, t.z), 5, Paint()..color = col);
      _text(canvas, t.id.length > 4 ? t.id.substring(t.id.length - 4) : t.id, p(t.x, t.y, t.z) + const Offset(7, -6),
          TextStyle(fontSize: 10, color: col));
    }

    // 드론: 궤적(바닥) + 높이 기둥 + 그림자 + 아이콘
    if (drone != null) {
      final stale = drone.age > const Duration(seconds: 2);
      final col = stale ? Colors.grey : const Color(0xFF1565C0);
      if (drone.trail.length > 1) {
        final path = Path();
        for (var i = 0; i < drone.trail.length; i++) {
          final s = p(drone.trail[i].dx, drone.trail[i].dy, 0);
          i == 0 ? path.moveTo(s.dx, s.dy) : path.lineTo(s.dx, s.dy);
        }
        canvas.drawPath(path, Paint()
          ..color = col.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
      }
      _floorCircle(canvas, proj, drone.xy, math.max(drone.stdev, 0.05), Paint()..color = col.withValues(alpha: 0.15));
      canvas.drawLine(p(drone.x, drone.y, 0), p(drone.x, drone.y, droneZ), Paint()
        ..color = col.withValues(alpha: 0.6)
        ..strokeWidth = 1.5);
      final dp = p(drone.x, drone.y, droneZ);
      if (w.droneSelected) {
        canvas.drawCircle(dp, 22, Paint()
          ..color = const Color(0xFFFFA000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
      }
      _quad(canvas, dp, col);
      _text(canvas, '드론  h=${droneZ.toStringAsFixed(2)}m${w.droneHeight != null ? " (ToF)" : ""}', dp + const Offset(20, 8),
          TextStyle(fontSize: 12, color: col, fontWeight: FontWeight.bold));
    }

    _text(canvas, '드래그: 회전 · Shift+드래그: 이동 · 휠: 확대 · 바닥 클릭: 목표', Offset(10, size.height - 22),
        TextStyle(fontSize: 11, color: Colors.grey.shade600));
  }

  void _floorCircle(Canvas canvas, _Projection proj, Offset c, double r, Paint paint) {
    final path = Path();
    for (var i = 0; i <= 32; i++) {
      final a = i / 32 * 2 * math.pi;
      final s = proj.p(c.dx + r * math.cos(a), c.dy + r * math.sin(a), 0);
      i == 0 ? path.moveTo(s.dx, s.dy) : path.lineTo(s.dx, s.dy);
    }
    canvas.drawPath(path, paint);
  }

  void _quad(Canvas canvas, Offset c, Color color) {
    final arm = Paint()
      ..color = color
      ..strokeWidth = 3;
    const d = 11.0;
    canvas.drawLine(c + const Offset(-d, -d), c + const Offset(d, d), arm);
    canvas.drawLine(c + const Offset(-d, d), c + const Offset(d, -d), arm);
    final rotor = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final o in const [Offset(-d, -d), Offset(d, d), Offset(-d, d), Offset(d, -d)]) {
      canvas.drawCircle(c + o, 6, rotor);
    }
    canvas.drawCircle(c, 4, Paint()..color = color);
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final len = (b - a).distance;
    if (len < 1) return;
    final dir = (b - a) / len;
    for (var s = 0.0; s < len; s += 12) {
      canvas.drawLine(a + dir * s, a + dir * math.min(s + 7, len), paint);
    }
  }

  void _text(Canvas canvas, String s, Offset at, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
