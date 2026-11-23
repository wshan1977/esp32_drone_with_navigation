import 'package:flutter/material.dart';

import '../app/services.dart';
import 'widgets.dart';

/// 단계별 수동 스로틀 시험 (STAB 모드, MANUAL_CONTROL).
/// 5% 단위로 올리며 단계마다 실제 추력·전압·고도를 기록해 이륙 추력(호버 추력)과 전압 강하를 파악한다.
class ThrottleTest extends StatefulWidget {
  final AppServices s;
  const ThrottleTest({super.key, required this.s});

  @override
  State<ThrottleTest> createState() => _ThrottleTestState();
}

class _Row {
  final double command, thrust, altitude, climb;
  final double? volts;
  _Row(this.command, this.thrust, this.volts, this.altitude, this.climb);
}

class _ThrottleTestState extends State<ThrottleTest> {
  final List<_Row> _rows = [];

  @override
  Widget build(BuildContext context) {
    final link = widget.s.link;
    final on = link.manualThrottle != null;
    final cmd = link.manualThrottle ?? 0;
    final small = TextStyle(fontSize: 12, color: Colors.grey.shade700);
    return Card(
      color: Colors.blueGrey.shade50,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('수동 스로틀 (단계 시험)', style: TextStyle(fontWeight: FontWeight.bold))),
            Switch(
              value: on,
              onChanged: link.flying ? null : (v) => link.setManualThrottle(v ? 0 : null),
            ),
          ]),
          if (!on)
            Text('켜면 슬라이더 값을 드론에 계속 보냅니다(20 Hz). 시동은 0%일 때만 걸립니다.', style: small)
          else ...[
            Row(children: [
              Text('${(cmd * 100).round()}%', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    '실제 추력 ${(link.thrust * 100).toStringAsFixed(0)}%\n'
                    '${link.batteryV == null ? "" : "${link.batteryV!.toStringAsFixed(2)} V · "}'
                    '${link.altitude == null ? "고도 -" : "고도 ${link.altitude!.toStringAsFixed(2)} m"}',
                    style: small),
              ),
            ]),
            _MotorBars(motors: link.motors, armed: link.armed),
            Slider(
              value: cmd,
              divisions: 20, // 5% 단계
              label: '${(cmd * 100).round()}%',
              onChanged: (v) => link.setManualThrottle(v),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (final d in const [-5, -1, 1, 5])
                SizedBox(
                  width: 50,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => link.setManualThrottle(cmd + d / 100),
                    child: Text(d > 0 ? '+$d' : '$d'),
                  ),
                ),
              SizedBox(
                width: 44,
                child: FilledButton(
                  style: FilledButton.styleFrom(padding: EdgeInsets.zero, backgroundColor: Colors.red.shade700),
                  onPressed: () => link.setManualThrottle(0),
                  child: const Text('0'),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: const Text('단계 기록'),
                  onPressed: () => setState(() =>
                      _rows.add(_Row(cmd, link.thrust, link.batteryV, link.altitude ?? double.nan, link.climbRate))),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton(
                  onPressed: link.armed && link.thrust > 0.15 ? () => _saveHover(link.thrust) : null,
                  child: const Text('호버 추력 저장', style: TextStyle(fontSize: 12)),
                ),
              ),
            ]),
          ],
          if (_rows.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [
              Text('기록 ${_rows.length}개', style: small),
              const Spacer(),
              TextButton(onPressed: () => setState(_rows.clear), child: const Text('지우기')),
            ]),
            Table(
              columnWidths: const {0: FlexColumnWidth(1), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1.2), 3: FlexColumnWidth(1.2)},
              children: [
                _tr(['명령', '추력', '전압', '고도'], bold: true),
                for (final r in _rows.reversed.take(15))
                  _tr([
                    '${(r.command * 100).round()}%',
                    '${(r.thrust * 100).round()}%',
                    r.volts == null ? '-' : r.volts!.toStringAsFixed(2),
                    r.altitude.isNaN ? '-' : r.altitude.toStringAsFixed(2),
                  ]),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Text('뜨기 시작하는 단계의 "실제 추력"이 호버 추력입니다. 0.3m 이상 뜨면 바로 내리세요(수평 위치 제어 없음).',
              style: small),
        ]),
      ),
    );
  }

  TableRow _tr(List<String> cells, {bool bold = false}) => TableRow(children: [
        for (final c in cells)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(c,
                style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
      ]);

  void _saveHover(double thrust) {
    widget.s.link.setParam('ALT_HOVER_THR', double.parse(thrust.toStringAsFixed(2)));
    showSnack(context, 'ALT_HOVER_THR = ${thrust.toStringAsFixed(2)} 저장 (고도 유지 이륙에 사용)');
  }
}

/// 펌웨어가 각 모터에 명령한 출력 (기체를 위에서 본 배치, 기수 위).
/// 시동 중에 0%인 모터는 제어기가 끈 것(빨강) — 명령이 있는데 안 돌면 하드웨어 문제.
class _MotorBars extends StatelessWidget {
  final List<double> motors; // 0=RL 1=RR 2=FR 3=FL
  final bool armed;
  const _MotorBars({required this.motors, required this.armed});

  Widget _bar(String name, double v) {
    final stopped = armed && v <= 0.001;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Column(children: [
          Text('$name ${(v * 100).round()}%',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: stopped ? Colors.red.shade700 : Colors.black87,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          LinearProgressIndicator(
            value: v.clamp(0.0, 1.0),
            minHeight: 8,
            color: stopped ? Colors.red : Colors.blue,
            backgroundColor: stopped ? Colors.red.shade100 : Colors.blue.shade50,
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Row(children: [_bar('FL', motors[3]), _bar('FR', motors[2])]),
      Row(children: [_bar('RL', motors[0]), _bar('RR', motors[1])]),
    ]);
  }
}
