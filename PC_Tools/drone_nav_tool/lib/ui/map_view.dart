import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../aoa/aoa_client.dart';
import '../aoa/floor_plan.dart';
import '../aoa/locationx_api.dart';
import '../control/nav_controller.dart';

/// world(m, y-up) → 화면 px 변환.
class MapTransform {
  final double pxPerM;
  final Offset pan; // world 원점의 화면 위치

  const MapTransform({this.pxPerM = 80, this.pan = const Offset(80, 400)});

  Offset toScreen(Offset w) => Offset(pan.dx + w.dx * pxPerM, pan.dy - w.dy * pxPerM);
  Offset toWorld(Offset s) => Offset((s.dx - pan.dx) / pxPerM, -(s.dy - pan.dy) / pxPerM);

  MapTransform zoomAt(Offset focus, double factor) {
    final newPx = (pxPerM * factor).clamp(5.0, 2000.0);
    final w = toWorld(focus);
    return MapTransform(
        pxPerM: newPx, pan: Offset(focus.dx - w.dx * newPx, focus.dy + w.dy * newPx));
  }

  /// world 사각형이 화면에 꽉 차게.
  static MapTransform fit(Rect world, Size size, {double margin = 60}) {
    final w = math.max(world.width, 1.0), h = math.max(world.height, 1.0);
    final px = math.min((size.width - 2 * margin) / w, (size.height - 2 * margin) / h)
        .clamp(5.0, 2000.0);
    final c = world.center;
    return MapTransform(
        pxPerM: px, pan: Offset(size.width / 2 - c.dx * px, size.height / 2 + c.dy * px));
  }
}

class MapView extends StatefulWidget {
  final AoaClient aoa;
  final FloorPlan? plan;
  final List<LxLocator> locators;
  final String droneTagId;
  final Offset? target;
  final bool droneSelected;
  final Rect? geofence;
  final VoidCallback onDroneTap;
  final ValueChanged<Offset> onMapTap;
  final NavController? nav;

  const MapView({
    super.key,
    required this.aoa,
    required this.plan,
    required this.locators,
    required this.droneTagId,
    required this.target,
    required this.droneSelected,
    required this.geofence,
    required this.onDroneTap,
    required this.onMapTap,
    this.nav,
  });

  @override
  State<MapView> createState() => MapViewState();
}

class MapViewState extends State<MapView> {
  MapTransform _t = const MapTransform();
  Offset? _hover;
  Size _size = Size.zero;
  bool _fitted = false;

  /// 로케이터·태그가 모두 보이게 맞춘다.
  void fit() {
    Rect? r;
    for (final p in [
      for (final l in widget.locators) Offset(l.x, l.y),
      for (final t in widget.aoa.tags.values) t.xy,
    ]) {
      final pr = Rect.fromCenter(center: p, width: 0.01, height: 0.01);
      r = r == null ? pr : r.expandToInclude(pr);
    }
    r ??=const Rect.fromLTWH(0, 0, 5, 5);
    setState(() => _t = MapTransform.fit(r!, _size));
  }

  TagTrack? get _drone => widget.aoa.tags[widget.droneTagId];

  void _onTap(Offset pos) {
    final d = _drone;
    if (d != null && (_t.toScreen(d.xy) - pos).distance < 24) {
      widget.onDroneTap();
      return;
    }
    widget.onMapTap(_t.toWorld(pos));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      _size = box.biggest;
      if (!_fitted && _size.width > 0) {
        _fitted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => fit());
      }
      return Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            setState(() => _t = _t.zoomAt(e.localPosition, e.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15));
          }
        },
        child: MouseRegion(
          onHover: (e) => setState(() => _hover = e.localPosition),
          onExit: (_) => setState(() => _hover = null),
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            onTapUp: (d) => _onTap(d.localPosition),
            onPanUpdate: (d) =>
                setState(() => _t = MapTransform(pxPerM: _t.pxPerM, pan: _t.pan + d.delta)),
            child: ClipRect(
              child: CustomPaint(
                size: Size.infinite,
                painter: _MapPainter(
                  t: _t,
                  aoa: widget.aoa,
                  plan: widget.plan,
                  locators: widget.locators,
                  droneTagId: widget.droneTagId,
                  target: widget.target,
                  droneSelected: widget.droneSelected,
                  geofence: widget.geofence,
                  hover: _hover,
                  nav: widget.nav,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _MapPainter extends CustomPainter {
  final MapTransform t;
  final AoaClient aoa;
  final FloorPlan? plan;
  final List<LxLocator> locators;
  final String droneTagId;
  final Offset? target;
  final bool droneSelected;
  final Rect? geofence;
  final Offset? hover;
  final NavController? nav;

  _MapPainter({
    required this.t,
    required this.aoa,
    required this.plan,
    required this.locators,
    required this.droneTagId,
    required this.target,
    required this.droneSelected,
    required this.geofence,
    required this.hover,
    this.nav,
  });

  static const _bg = Color(0xFFF4F6F8);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
    _drawFloorImage(canvas);
    _drawGrid(canvas, size);
    if (geofence != null) {
      canvas.drawRect(
          Rect.fromPoints(t.toScreen(geofence!.topLeft), t.toScreen(geofence!.bottomRight)),
          Paint()
            ..color = const Color(0xFF2E7D32)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
    _drawLocators(canvas);
    for (final tag in aoa.tags.values) {
      if (tag.id != droneTagId) _drawTag(canvas, tag, false);
    }
    final drone = aoa.tags[droneTagId];
    if (drone != null && target != null) {
      _dashedLine(canvas, t.toScreen(drone.xy), t.toScreen(target!),
          Paint()
            ..color = const Color(0xFFD84315)
            ..strokeWidth = 2);
    }
    if (target != null) _drawTarget(canvas, t.toScreen(target!));
    if (drone != null) _drawTag(canvas, drone, true);
    if (drone != null) _drawNav(canvas, drone);
    _drawHover(canvas, size);
  }

  void _drawFloorImage(Canvas canvas) {
    final img = plan?.image;
    if (img == null) return;
    // image px → world: ((px - o) * mpp, -(py - o) * mpp) → screen
    final k = t.pxPerM * plan!.metersPerPixel;
    canvas.save();
    canvas.translate(t.pan.dx - k * plan!.originPx.dx, t.pan.dy - k * plan!.originPx.dy);
    canvas.scale(k);
    canvas.drawImage(img, Offset.zero, Paint()..color = const Color(0x99FFFFFF));
    canvas.restore();
  }

  void _drawGrid(Canvas canvas, Size size) {
    final step = t.pxPerM < 20 ? 5.0 : (t.pxPerM > 300 ? 0.5 : 1.0);
    final tl = t.toWorld(Offset.zero), br = t.toWorld(Offset(size.width, size.height));
    final minor = Paint()
      ..color = const Color(0x22000000)
      ..strokeWidth = 1;
    final label = TextStyle(fontSize: 10, color: Colors.grey.shade600);
    for (var x = (tl.dx / step).floor() * step; x <= br.dx; x += step) {
      final sx = t.toScreen(Offset(x, 0)).dx;
      canvas.drawLine(Offset(sx, 0), Offset(sx, size.height), minor);
      _text(canvas, '${_fmt(x)}m', Offset(sx + 2, size.height - 14), label);
    }
    for (var y = (br.dy / step).floor() * step; y <= tl.dy; y += step) {
      final sy = t.toScreen(Offset(0, y)).dy;
      canvas.drawLine(Offset(0, sy), Offset(size.width, sy), minor);
      _text(canvas, '${_fmt(y)}m', Offset(2, sy - 12), label);
    }
    // 원점 축
    final o = t.toScreen(Offset.zero);
    canvas.drawLine(o, o + const Offset(40, 0), Paint()
      ..color = Colors.red
      ..strokeWidth = 2);
    canvas.drawLine(o, o + const Offset(0, -40), Paint()
      ..color = Colors.green
      ..strokeWidth = 2);
    _text(canvas, 'x', o + const Offset(42, -7), const TextStyle(color: Colors.red, fontSize: 11));
    _text(canvas, 'y', o + const Offset(-4, -54), const TextStyle(color: Colors.green, fontSize: 11));
  }

  void _drawLocators(Canvas canvas) {
    for (final l in locators) {
      final p = t.toScreen(Offset(l.x, l.y));
      canvas.drawRect(Rect.fromCenter(center: p, width: 14, height: 14),
          Paint()..color = const Color(0xFF455A64));
      _text(canvas, l.shortId, p + const Offset(9, -6),
          const TextStyle(fontSize: 11, color: Color(0xFF455A64), fontWeight: FontWeight.w600));
    }
  }

  void _drawTag(Canvas canvas, TagTrack tag, bool isDrone) {
    final stale = tag.age > const Duration(seconds: 2);
    final color = isDrone
        ? (stale ? Colors.grey : const Color(0xFF1565C0))
        : Colors.blueGrey.withValues(alpha: stale ? 0.3 : 0.7);
    // 궤적
    if (tag.trail.length > 1) {
      final path = Path()..moveTo(t.toScreen(tag.trail.first).dx, t.toScreen(tag.trail.first).dy);
      for (final p in tag.trail.skip(1)) {
        final s = t.toScreen(p);
        path.lineTo(s.dx, s.dy);
      }
      canvas.drawPath(path, Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isDrone ? 2 : 1);
    }
    final c = t.toScreen(tag.xy);
    // 표준편차 타원
    canvas.drawOval(
        Rect.fromCenter(
            center: c,
            width: math.max(2 * tag.xStd * t.pxPerM, 4),
            height: math.max(2 * tag.yStd * t.pxPerM, 4)),
        Paint()..color = color.withValues(alpha: 0.12));
    if (isDrone) {
      if (droneSelected) {
        canvas.drawCircle(c, 22, Paint()
          ..color = const Color(0xFFFFA000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
      }
      _drawQuad(canvas, c, color);
      _text(canvas, '드론  z=${tag.z.toStringAsFixed(2)}m', c + const Offset(20, 8),
          TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold));
    } else {
      canvas.drawCircle(c, 5, Paint()..color = color);
      _text(canvas, _short(tag.id), c + const Offset(7, -6), TextStyle(fontSize: 10, color: color));
    }
  }

  /// 위치 제어 중: 유지 목표(초록 +), 명령 가속도(주황, 1 m/s² = 0.5 m), 추정 속도(파랑, 1 m/s = 1 m)
  void _drawNav(Canvas canvas, TagTrack drone) {
    final n = nav;
    if (n == null || n.state == NavState.idle) return;
    final c = t.toScreen(n.pc.pos ?? drone.xy);
    final tg = n.target;
    if (tg != null) {
      final p = t.toScreen(tg);
      final g = Paint()
        ..color = const Color(0xFF2E7D32)
        ..strokeWidth = 2.5;
      canvas.drawLine(p + const Offset(-8, 0), p + const Offset(8, 0), g);
      canvas.drawLine(p + const Offset(0, -8), p + const Offset(0, 8), g);
    }
    _arrow(canvas, c, t.toScreen((n.pc.pos ?? drone.xy) + n.pc.accel * 0.5) , const Color(0xFFEF6C00));
    _arrow(canvas, c, t.toScreen((n.pc.pos ?? drone.xy) + n.pc.vel), const Color(0xFF1E88E5));
  }

  void _arrow(Canvas canvas, Offset a, Offset b, Color color) {
    final len = (b - a).distance;
    if (len < 4) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(a, b, paint);
    final dir = (b - a) / len;
    final side = Offset(-dir.dy, dir.dx);
    canvas.drawPath(
        Path()
          ..moveTo(b.dx, b.dy)
          ..lineTo((b - dir * 10 + side * 5).dx, (b - dir * 10 + side * 5).dy)
          ..lineTo((b - dir * 10 - side * 5).dx, (b - dir * 10 - side * 5).dy)
          ..close(),
        Paint()..color = color);
  }

  void _drawQuad(Canvas canvas, Offset c, Color color) {
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

  void _drawTarget(Canvas canvas, Offset p) {
    final paint = Paint()
      ..color = const Color(0xFFD84315)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(p, 12, paint);
    canvas.drawCircle(p, 4, paint..style = PaintingStyle.fill);
    canvas.drawLine(p + const Offset(-18, 0), p + const Offset(18, 0), paint..strokeWidth = 1.5);
    canvas.drawLine(p + const Offset(0, -18), p + const Offset(0, 18), paint);
    final w = t.toWorld(p);
    _text(canvas, '목표 (${w.dx.toStringAsFixed(2)}, ${w.dy.toStringAsFixed(2)})',
        p + const Offset(16, -22),
        const TextStyle(fontSize: 12, color: Color(0xFFD84315), fontWeight: FontWeight.bold));
  }

  void _drawHover(Canvas canvas, Size size) {
    if (hover == null) return;
    final w = t.toWorld(hover!);
    _text(canvas, 'x ${w.dx.toStringAsFixed(2)}  y ${w.dy.toStringAsFixed(2)} m',
        Offset(size.width - 170, 8), const TextStyle(fontSize: 12, color: Colors.black87));
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    final len = (b - a).distance;
    if (len < 1) return;
    final dir = (b - a) / len;
    for (var s = 0.0; s < len; s += 12) {
      canvas.drawLine(a + dir * s, a + dir * math.min(s + 7, len), paint);
    }
  }

  void _text(Canvas canvas, String s, Offset at, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, at);
  }

  static String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
  static String _short(String id) => id.length > 4 ? id.substring(id.length - 4) : id;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
