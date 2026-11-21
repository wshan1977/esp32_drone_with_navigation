import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

/// LocationX 위치설정도구 프로젝트 파일(.lxpos.json)에서 읽은 도면과 로케이터 배치.
/// 좌표 규약은 locationx_install_tool/lib/canvas/world_transform.dart와 같다:
/// world(m, y-up) ↔ image px(y-down): px = originPx + (x, -y) / metersPerPixel
class FloorPlan {
  final String path;
  final ui.Image? image;
  final double metersPerPixel;
  final ui.Offset originPx;
  final List<LocatorPos> locators;

  FloorPlan({
    required this.path,
    this.image,
    this.metersPerPixel = 0.05,
    this.originPx = ui.Offset.zero,
    this.locators = const [],
  });

  /// 로케이터가 둘러싼 사각형 (m). 로케이터가 2개 미만이면 null.
  ui.Rect? get locatorBounds {
    if (locators.length < 2) return null;
    var r = ui.Rect.fromPoints(locators.first.xy, locators.first.xy);
    for (final l in locators) {
      r = r.expandToInclude(ui.Rect.fromPoints(l.xy, l.xy));
    }
    return r;
  }

  static Future<FloorPlan> load(String path) async {
    final j = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    ui.Offset off(dynamic v) => v is Map
        ? ui.Offset((v['x'] as num?)?.toDouble() ?? 0, (v['y'] as num?)?.toDouble() ?? 0)
        : ui.Offset.zero;

    final locators = <LocatorPos>[
      if (j['placements'] is List)
        for (final p in j['placements'] as List)
          if (p is Map && p['coordinate'] is Map)
            LocatorPos(
              id: p['locatorId']?.toString() ?? '',
              x: ((p['coordinate'] as Map)['x'] as num?)?.toDouble() ?? 0,
              y: ((p['coordinate'] as Map)['y'] as num?)?.toDouble() ?? 0,
              z: ((p['coordinate'] as Map)['z'] as num?)?.toDouble() ?? 0,
            ),
    ];

    ui.Image? image;
    final imgPath = j['floorPlanImagePath']?.toString();
    if (imgPath != null && imgPath.isNotEmpty && File(imgPath).existsSync()) {
      final codec = await ui.instantiateImageCodec(await File(imgPath).readAsBytes());
      image = (await codec.getNextFrame()).image;
    }

    return FloorPlan(
      path: path,
      image: image,
      metersPerPixel: (j['metersPerPixel'] as num?)?.toDouble() ?? 0.05,
      originPx: off(j['originPx']),
      locators: locators,
    );
  }
}

class LocatorPos {
  final String id;
  final double x, y, z;
  LocatorPos({required this.id, required this.x, required this.y, required this.z});

  ui.Offset get xy => ui.Offset(x, y);
  String get shortId => id.length >= 4 ? id.substring(id.length - 4) : id;
}
