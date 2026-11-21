import 'dart:io';
import 'dart:ui' as ui;

import 'package:drone_nav_tool/aoa/aoa_client.dart';
import 'package:drone_nav_tool/aoa/locationx_api.dart';
import 'package:drone_nav_tool/ui/map3d_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 3D 보기를 현장 배치(로케이터 4개)로 그려 PNG로 저장한다 (육안 확인용, RENDER_OUT 지정 시).
void main() {
  testWidgets('3D view renders locators, drone and target', (tester) async {
    final out = Platform.environment['RENDER_OUT'];
    final aoa = AoaClient();
    aoa.tags['ble-pd-30FB10657F77'] = TagTrack('ble-pd-30FB10657F77')
      ..x = 1.2
      ..y = -2.0
      ..z = 0
      ..xStd = 0.1
      ..yStd = 0.15;
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(900, 600));
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: Map3DView(
          aoa: aoa,
          locators: [
            LxLocator('ble-pd-4C5BB3CA792E', 3.0, 0.0, 3.0),
            LxLocator('ble-pd-4C5BB3CAD71E', 0.0, 0.06, 3.0),
            LxLocator('ble-pd-4C5BB3CA7924', 0.0, -4.3, 2.3),
            LxLocator('ble-pd-4C5BB3CA7ACD', 2.5, -4.3, 3.0),
          ],
          droneTagId: 'ble-pd-30FB10657F77',
          droneHeight: 0.8,
          target: const Offset(2.0, -3.0),
          droneSelected: true,
          geofence: const Rect.fromLTRB(0.5, -3.8, 2.5, -0.44),
          onDroneTap: () {},
          onMapTap: (_) {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(Map3DView), findsOneWidget);
    if (out != null) {
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await boundary.toImage();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File(out).writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
    aoa.dispose(); // 주기 타이머 정리 (테스트는 끝날 때 남은 타이머를 허용하지 않음)
  });
}
