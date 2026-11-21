import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../aoa/aoa_client.dart';
import '../aoa/floor_plan.dart';
import '../aoa/locationx_api.dart';
import '../app/services.dart';
import 'locationx_dialog.dart';
import 'map3d_view.dart';
import 'map_view.dart';
import 'widgets.dart';

/// 지도 + 드론 패널. 드론 아이콘 클릭 → 패널, 패널이 열린 상태에서 지도 클릭 → 목표점.
class FlightPage extends StatefulWidget {
  final AppServices s;
  const FlightPage({super.key, required this.s});

  @override
  State<FlightPage> createState() => _FlightPageState();
}

class _FlightPageState extends State<FlightPage> {
  final _mapKey = GlobalKey<MapViewState>();
  final _map3dKey = GlobalKey<Map3DViewState>();
  bool _view3d = false;
  bool _droneSelected = false;

  AppServices get s => widget.s;

  /// 서버에서 받은 로케이터, 없으면 프로젝트 파일의 배치.
  List<LxLocator> get _locators => s.aoa.locators.isNotEmpty
      ? s.aoa.locators
      : [for (final l in s.plan.value?.locators ?? const <LocatorPos>[]) LxLocator(l.id, l.x, l.y, l.z)];

  /// 로케이터 사각형에서 0.5m 안쪽 (설치 가이드: 벽에서 0.5m 이상).
  Rect? get _geofence {
    final ls = _locators;
    if (ls.length < 2) return null;
    var r = Rect.fromPoints(Offset(ls.first.x, ls.first.y), Offset(ls.first.x, ls.first.y));
    for (final l in ls) {
      r = r.expandToInclude(Rect.fromPoints(Offset(l.x, l.y), Offset(l.x, l.y)));
    }
    return r.deflate(0.5);
  }

  Future<void> _openProject() async {
    final r = await FilePicker.platform.pickFiles(
        dialogTitle: 'LocationX 프로젝트(.lxpos.json) 열기',
        type: FileType.custom,
        allowedExtensions: ['json']);
    final path = r?.files.single.path;
    if (path == null) return;
    try {
      s.plan.value = await FloorPlan.load(path);
      s.settings.projectPath = path;
      s.settings.save();
      _mapKey.currentState?.fit();
    } catch (e) {
      if (mounted) showSnack(context, '프로젝트를 열 수 없음: $e');
    }
  }

  void _onMapTap(Offset world) {
    if (!_droneSelected) return;
    final g = _geofence;
    if (g != null && !g.contains(world)) {
      showSnack(context, '비행 영역(로케이터 안쪽 0.5m) 밖입니다');
      return;
    }
    s.target.value = world;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s.aoa, s.plan, s.target, s.link]),
      builder: (context, _) => Column(
        children: [
          _topBar(),
          const Divider(height: 1),
          Expanded(
            child: Stack(
              children: [
                if (_view3d)
                  Map3DView(
                    key: _map3dKey,
                    aoa: s.aoa,
                    locators: _locators,
                    droneTagId: s.settings.droneTagId,
                    droneHeight: s.link.connected ? (s.link.altitude ?? s.link.tofM) : null,
                    target: s.target.value,
                    droneSelected: _droneSelected,
                    geofence: _geofence,
                    onDroneTap: () => setState(() => _droneSelected = !_droneSelected),
                    onMapTap: _onMapTap,
                  )
                else
                  MapView(
                    key: _mapKey,
                    aoa: s.aoa,
                    plan: s.plan.value,
                    locators: _locators,
                    droneTagId: s.settings.droneTagId,
                    target: s.target.value,
                    droneSelected: _droneSelected,
                    geofence: _geofence,
                    onDroneTap: () => setState(() => _droneSelected = !_droneSelected),
                    onMapTap: _onMapTap,
                  ),
                Positioned(left: 12, top: 12, child: _mapButtons()),
                if (s.aoa.tags[s.settings.droneTagId] == null)
                  Positioned(left: 12, bottom: 12, child: _hint()),
                if (_droneSelected)
                  Positioned(
                    right: 12,
                    top: 12,
                    bottom: 12,
                    child: DronePanel(s: s, onClose: () => setState(() => _droneSelected = false)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    final aoa = s.aoa;
    final tagIds = aoa.tags.keys.toList();
    final selected = tagIds.contains(s.settings.droneTagId) ? s.settings.droneTagId : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.tonalIcon(
            onPressed: () => LocationXDialog.show(context, s),
            icon: Icon(aoa.source == AoaSource.cloud ? Icons.cloud : Icons.lan),
            label: const Text('LocationX 연결'),
          ),
          StatusDot(
            ok: aoa.status == AoaStatus.connected,
            label: switch (aoa.status) {
              AoaStatus.connected => '${aoa.source == AoaSource.cloud ? "외부망" : "내부망"} ${aoa.host} · '
                  '로케이터 ${aoa.locators.length} · 태그 ${aoa.tags.length}',
              AoaStatus.connecting => '연결 중…',
              AoaStatus.error => '연결 실패 (${aoa.host})',
              AoaStatus.disconnected => '연결 안 됨',
            },
            tooltip: aoa.error,
          ),
          const SizedBox(width: 12),
          const Text('드론 태그', style: TextStyle(fontWeight: FontWeight.w600)),
          DropdownButton<String>(
            value: selected,
            hint: Text(s.settings.droneTagId.isEmpty ? '선택' : '${s.settings.droneTagId} (수신 없음)'),
            items: [
              for (final id in tagIds)
                DropdownMenuItem(
                    value: id, child: Text('$id  (${aoa.tags[id]!.rateHz.toStringAsFixed(0)}Hz)')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => s.settings.droneTagId = v);
              s.settings.save();
            },
          ),
        ],
      ),
    );
  }

  Widget _mapButtons() => Card(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('2D')),
                ButtonSegment(value: true, label: Text('3D')),
              ],
              selected: {_view3d},
              onSelectionChanged: (v) => setState(() => _view3d = v.first),
            ),
          ),
          IconButton(
              tooltip: 'LocationX 프로젝트(.lxpos.json) 열기 — 도면 표시 (2D)',
              icon: const Icon(Icons.folder_open),
              onPressed: _openProject),
          IconButton(
              tooltip: _view3d ? '보기 초기화' : '화면 맞춤',
              icon: const Icon(Icons.fit_screen),
              onPressed: () => _view3d ? _map3dKey.currentState?.reset() : _mapKey.currentState?.fit()),
          IconButton(
              tooltip: '궤적 지우기', icon: const Icon(Icons.cleaning_services), onPressed: s.aoa.clearTrails),
          IconButton(
              tooltip: '목표점 지우기',
              icon: const Icon(Icons.location_off),
              onPressed: () => s.target.value = null),
        ]),
      );

  Widget _hint() => Card(
        color: Colors.amber.shade50,
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Text('① LocationX 연결 → ② 상단에서 드론 태그 선택 → ③ 지도에서 드론 아이콘 클릭'),
        ),
      );
}

/// 드론 아이콘을 클릭하면 열리는 조작 패널.
class DronePanel extends StatelessWidget {
  final AppServices s;
  final VoidCallback onClose;
  const DronePanel({super.key, required this.s, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final link = s.link;
    final tag = s.aoa.tags[s.settings.droneTagId];
    final target = s.target.value;
    final dist = (tag != null && target != null) ? (target - tag.xy).distance : null;
    return SizedBox(
      width: 300,
      child: Card(
        elevation: 4,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Row(children: [
              const Icon(Icons.flight, color: Color(0xFF1565C0)),
              const SizedBox(width: 8),
              const Expanded(
                  child: Text('드론', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
            ]),
            StatusDot(
                ok: link.connected,
                label: link.connected ? '드론 연결됨 (${link.droneAddress?.address})' : '드론 연결 안 됨'),
            const SizedBox(height: 8),
            InfoRow('시동', link.armed ? '켜짐' : '꺼짐', color: link.armed ? Colors.red : null),
            InfoRow('모드', link.mode?.label ?? '-'),
            InfoRow('배터리', link.batteryV == null ? '-' : '${link.batteryV!.toStringAsFixed(2)} V',
                color: (link.batteryV ?? 9) < 3.5 ? Colors.orange : null),
            InfoRow('고도',
                link.altitude == null ? (link.tofPresent ? 'ToF 무효' : '-') : '${link.altitude!.toStringAsFixed(2)} m'
                    '${link.altitudeTarget == null ? "" : " → ${link.altitudeTarget!.toStringAsFixed(2)} m"}'),
            if (link.flying)
              InfoRow('상승 / 추력', '${link.climbRate.toStringAsFixed(2)} m/s · ${(link.thrust * 100).toStringAsFixed(0)}%'),
            InfoRow('자세', 'R ${link.roll.toStringAsFixed(1)}°  P ${link.pitch.toStringAsFixed(1)}°'),
            const Divider(),
            InfoRow('AoA 위치',
                tag == null ? '수신 없음' : '(${tag.x.toStringAsFixed(2)}, ${tag.y.toStringAsFixed(2)}, ${tag.z.toStringAsFixed(2)})'),
            if (tag != null)
              InfoRow('AoA 품질', '${tag.rateHz.toStringAsFixed(0)} Hz · σ ${(tag.stdev * 100).toStringAsFixed(0)} cm',
                  color: tag.stdev > 0.3 || tag.rateHz < 10 ? Colors.orange : null),
            InfoRow('목표', target == null ? '지도를 클릭해 지정' : '(${target.dx.toStringAsFixed(2)}, ${target.dy.toStringAsFixed(2)})'),
            if (dist != null) InfoRow('남은 거리', '${dist.toStringAsFixed(2)} m'),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('시동'),
                  onPressed: link.connected && !link.armed ? () => _confirmArm(context) : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.power_off),
                  label: const Text('시동 끄기'),
                  onPressed: link.connected && link.armed ? link.disarm : null,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            _FlightControls(s: s),
            if (link.lastMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  '드론: ${link.lastMessage}'
                  '${link.lastMessageTime == null ? "" : "  (${DateTime.now().difference(link.lastMessageTime!).inSeconds}초 전)"}',
                  style: TextStyle(
                      fontSize: 12,
                      color: RegExp('disarm|stopped|Low battery|lost', caseSensitive: false).hasMatch(link.lastMessage)
                          ? Colors.red.shade700
                          : Colors.grey.shade800),
                ),
              ),
            ],
            if (link.lastAck.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('응답: ${link.lastAck}', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmArm(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('시동을 겁니다'),
        content: const Text('모터가 돌 수 있습니다. 프롭 주변에 손·물건이 없는지 확인하세요.\n'
            '비상시: 상단 [비상정지] 또는 Space 키'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('시동')),
        ],
      ),
    );
    if (ok == true) s.link.arm();
  }
}

/// 이륙(높이 지정)·고도 조절·착륙. 이동은 위치 제어 구현 후.
class _FlightControls extends StatefulWidget {
  final AppServices s;
  const _FlightControls({required this.s});

  @override
  State<_FlightControls> createState() => _FlightControlsState();
}

class _FlightControlsState extends State<_FlightControls> {
  double _height = 0.8;

  @override
  Widget build(BuildContext context) {
    final link = widget.s.link;
    final canTakeoff = link.connected && link.armed && !link.flying && link.altitude != null;
    final target = link.commandedAltitude ?? _height;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('이륙 높이'),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: () => _change(-0.1),
        ),
        Text('${(link.flying ? target : _height).toStringAsFixed(1)} m',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () => _change(0.1),
        ),
      ]),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            icon: const Icon(Icons.flight_takeoff),
            label: const Text('이륙'),
            onPressed: canTakeoff ? () => link.takeoff(_height) : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.tonalIcon(
            icon: const Icon(Icons.flight_land),
            label: const Text('착륙'),
            onPressed: link.connected && link.flying ? link.land : null,
          ),
        ),
      ]),
      const SizedBox(height: 6),
      const Tooltip(
        message: '위치 제어(PC XY 제어) 구현 후 활성화됩니다',
        child: SizedBox(width: double.infinity, child: OutlinedButton(onPressed: null, child: Text('목표로 이동'))),
      ),
      const SizedBox(height: 6),
      Text(
        !link.armed
            ? '이륙하려면 먼저 시동을 거세요.'
            : link.altitude == null
                ? 'ToF 고도가 없어 이륙할 수 없습니다.'
                : link.flying
                    ? '고도 유지 중. +/−로 높이 조절, PC 연결이 1초 끊기면 자동 착륙합니다.'
                    : '이륙하면 고도를 유지하며 제자리 비행합니다 (수평 위치는 아직 수동 보정 필요).',
        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
      ),
    ]);
  }

  void _change(double d) {
    final link = widget.s.link;
    if (link.flying) {
      final h = ((link.commandedAltitude ?? link.altitude ?? _height) + d).clamp(0.2, 2.0);
      link.setAltitude(h);
    } else {
      _height = (_height + d).clamp(0.3, 1.5);
    }
    setState(() {});
  }
}
