import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/services.dart';
import 'widgets.dart';

/// 펌웨어 `ca` 명령(imu.ino calibrateAccel)을 PC에서 진행하는 화면.
/// 펌웨어는 각 단계마다 "n/6 ..."을 출력하고 8초 뒤 1초간 측정한다.
class CalibrationPage extends StatefulWidget {
  final AppServices s;
  const CalibrationPage({super.key, required this.s});

  @override
  State<CalibrationPage> createState() => _CalibrationPageState();
}

enum _Phase { idle, starting, pose, measuring, done, failed }

class _Step {
  final String title;
  final String detail;
  const _Step(this.title, this.detail);
}

const _steps = [
  _Step('수평', '윗면이 위로 오게 평평한 바닥에 내려놓으세요.'),
  _Step('기수 위로', '기수를 하늘로 향하게 세우세요. 꼬리가 바닥에 닿게, 바닥과 수직.'),
  _Step('기수 아래로', '기수를 바닥에 대고 세우세요. 꼬리가 위, 바닥과 수직.'),
  _Step('오른쪽(R) 면 아래', 'R 쪽 팔이 바닥에 닿게 세우세요. L 쪽이 위, 바닥과 수직.'),
  _Step('왼쪽(L) 면 아래', 'L 쪽 팔이 바닥에 닿게 세우세요. R 쪽이 위, 바닥과 수직.'),
  _Step('뒤집기', '완전히 뒤집어 윗면이 바닥에 닿게 수평으로 놓으세요.'),
];

class _CalibrationPageState extends State<CalibrationPage> {
  StreamSubscription<String>? _sub;
  Timer? _tick;
  String _lineBuf = '';
  _Phase _phase = _Phase.idle;
  int _step = 0; // 1..6
  DateTime _stepStart = DateTime.now();
  DateTime _lastProgress = DateTime.now();
  List<double>? _bias, _scale;
  String _error = '';

  // IMU 정보
  final List<String> _imuLines = [];
  bool _imuCapture = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.s.link.consoleStream.listen(_onConsole);
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_phase == _Phase.pose || _phase == _Phase.measuring || _phase == _Phase.starting) {
        if (DateTime.now().difference(_lastProgress) > const Duration(seconds: 25)) {
          _phase = _Phase.failed;
          _error = '드론 응답이 없습니다. 연결을 확인하고 다시 시작하세요.';
        } else if (_phase == _Phase.pose &&
            DateTime.now().difference(_stepStart) > const Duration(seconds: 8)) {
          _phase = _Phase.measuring;
        }
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _onConsole(String chunk) {
    _lineBuf += chunk;
    final lines = _lineBuf.split('\n');
    _lineBuf = lines.removeLast();
    for (final raw in lines) {
      final line = raw.trim();
      if (_imuCapture) _imuLines.add(line);
      _parseCalibration(line);
    }
    setState(() {});
  }

  static List<double>? _three(String line) {
    final nums = RegExp(r'-?\d+(\.\d+)?(e-?\d+)?')
        .allMatches(line.substring(line.indexOf(':') + 1))
        .map((m) => double.parse(m.group(0)!))
        .toList();
    return nums.length >= 3 ? nums.sublist(0, 3) : null;
  }

  void _parseCalibration(String line) {
    if (_phase == _Phase.idle || _phase == _Phase.done || _phase == _Phase.failed) return;
    final m = RegExp(r'^([1-6])/6').firstMatch(line);
    if (m != null) {
      _step = int.parse(m.group(1)!);
      _stepStart = DateTime.now();
      _lastProgress = _stepStart;
      _phase = _Phase.pose;
    } else if (line.startsWith('Calibration failed')) {
      _phase = _Phase.failed;
      _error = '보정 실패: 6가지 자세 중 같은 면이 두 번 바닥에 닿았습니다. 이전 보정값을 유지했습니다. '
          '그림대로 각 단계마다 다른 면이 바닥을 향하게 다시 보정하세요.';
    } else if (line.contains('calibration done')) {
      _lastProgress = DateTime.now();
    } else if (line.startsWith('accel bias:')) {
      _bias = _three(line);
      _lastProgress = DateTime.now();
    } else if (line.startsWith('accel scale:')) {
      _scale = _three(line);
      _phase = _Phase.done;
    } else if (line.startsWith('Calibrating accelerometer')) {
      _lastProgress = DateTime.now();
    }
  }

  void _start() {
    setState(() {
      _phase = _Phase.starting;
      _step = 0;
      _bias = null;
      _scale = null;
      _error = '';
      _lastProgress = DateTime.now();
    });
    widget.s.link.sendCli('ca');
  }

  Future<void> _readImu() async {
    setState(() {
      _imuLines.clear();
      _imuCapture = true;
    });
    widget.s.link.sendCli('imu');
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) setState(() => _imuCapture = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.s.link,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            SizedBox(width: 380, child: _liveCard()),
            SizedBox(width: 560, child: _wizardCard()),
            SizedBox(width: 380, child: _imuCard()),
          ],
        ),
      ),
    );
  }

  // ---- 실시간 상태 ----

  Widget _liveCard() {
    final l = widget.s.link;
    final accMag = math.sqrt(l.accX * l.accX + l.accY * l.accY + l.accZ * l.accZ);
    final level = l.roll.abs() < 2 && l.pitch.abs() < 2;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('실시간 자세', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          StatusDot(ok: l.connected, label: l.connected ? '드론 연결됨' : '드론 연결 안 됨'),
          const SizedBox(height: 12),
          Center(
            child: SizedBox(
                width: 200,
                height: 200,
                child: CustomPaint(painter: _HorizonPainter(l.roll, l.pitch))),
          ),
          const SizedBox(height: 12),
          InfoRow('Roll / Pitch', '${l.roll.toStringAsFixed(1)}° / ${l.pitch.toStringAsFixed(1)}°',
              color: l.connected ? (level ? Colors.green : null) : null),
          InfoRow('Yaw', '${l.yaw.toStringAsFixed(1)}°'),
          InfoRow('가속도 크기', '${accMag.toStringAsFixed(3)} g',
              color: l.connected ? ((accMag - 1).abs() < 0.05 ? Colors.green : Colors.orange) : null),
          InfoRow('착지 판단', l.landed == null ? '-' : (l.landed! ? '착지 (정상)' : '비행/움직임')),
          InfoRow('루프 속도', l.loopRate == null ? '-' : '${l.loopRate!.toStringAsFixed(0)} Hz'),
          const SizedBox(height: 8),
          Text('수평 바닥에 두었을 때 Roll/Pitch ±2° 이내, 가속도 1.00±0.05 g, 착지 판단이 "착지"면 보정 정상입니다.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        ]),
      ),
    );
  }

  // ---- 보정 마법사 ----

  Widget _wizardCard() {
    final running = _phase == _Phase.starting || _phase == _Phase.pose || _phase == _Phase.measuring;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('가속도계 보정 (6단계)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('프롭을 빼고, 박스 모서리나 벽에 대서 수직·수평을 맞추면 정확합니다. 각 단계 8초 안에 자세를 잡고 가만히 두세요.',
              style: TextStyle(color: Colors.grey.shade700)),
          const SizedBox(height: 12),
          if (!running) _orientationGuide(),
          const SizedBox(height: 12),
          _stepIndicator(),
          const SizedBox(height: 16),
          if (running && _step > 0) _currentStep(),
          if (_phase == _Phase.starting && _step == 0) const Text('드론에 보정 시작 명령을 보냈습니다…'),
          if (_phase == _Phase.done) _results(),
          if (_phase == _Phase.failed) Text(_error, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: widget.s.link.connected && !running ? _start : null,
            icon: const Icon(Icons.play_arrow),
            label: Text(_phase == _Phase.done ? '다시 보정' : '보정 시작'),
          ),
        ]),
      ),
    );
  }

  String _img(String name) => 'assets/calibration/${widget.s.settings.noseAtUsb ? 'u' : 'a'}_$name.png';

  /// 기수·L·R 참고 사진 + 기수 방향 선택.
  Widget _orientationGuide() => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.asset(_img('top'), width: 200, height: 200),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('기수 방향', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('안테나 쪽')),
                ButtonSegment(value: true, label: Text('USB 쪽')),
              ],
              selected: {widget.s.settings.noseAtUsb},
              onSelectionChanged: (v) {
                setState(() => widget.s.settings.noseAtUsb = v.first);
                widget.s.settings.save();
              },
            ),
            const SizedBox(height: 8),
            Text('확인 방법: 드론을 바닥에 두고 기수 쪽을 손으로 살짝 들면 왼쪽 "실시간 자세"의 Pitch가 +로 바뀌어야 합니다. '
                '−로 바뀌면 반대쪽이 기수입니다.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade800)),
            const SizedBox(height: 6),
            Text('보정은 6면을 한 번씩 바닥에 대기만 하면 되므로, 기수 방향을 잘못 골라도 보정 결과는 같습니다. '
                '기수 방향은 비행할 때 중요합니다.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          ]),
        ),
      ]);

  Widget _stepIndicator() => Row(children: [
        for (var i = 1; i <= 6; i++)
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: _phase == _Phase.done || i < _step
                    ? Colors.green.shade400
                    : (i == _step ? Colors.blue.shade400 : Colors.grey.shade300),
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Text('$i', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
      ]);

  Widget _currentStep() {
    final st = _steps[_step - 1];
    final left = 8 - DateTime.now().difference(_stepStart).inMilliseconds / 1000;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.asset(_img('step$_step'), width: 260, height: 260),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$_step/6  ${st.title}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(st.detail, style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 14),
          if (_phase == _Phase.pose)
            Text('측정까지 ${left.clamp(0, 8).toStringAsFixed(0)}초 — 자세를 잡으세요',
                style: const TextStyle(fontSize: 18, color: Colors.blue, fontWeight: FontWeight.w600))
          else
            const Text('측정 중… 움직이지 마세요',
                style: TextStyle(fontSize: 18, color: Colors.deepOrange, fontWeight: FontWeight.w600)),
        ]),
      ),
    ]);
  }

  Widget _results() {
    final b = _bias, sc = _scale;
    if (b == null || sc == null) return const Text('결과를 읽지 못했습니다.');
    bool scaleOk(double v) => (v - 1).abs() <= 0.1;
    bool biasOk(double v) => v.abs() <= 1.0;
    final allOk = sc.every(scaleOk) && b.every(biasOk);
    String f(List<double> v) => v.map((e) => e.toStringAsFixed(3)).join('   ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(allOk ? Icons.check_circle : Icons.error, color: allOk ? Colors.green : Colors.red, size: 28),
        const SizedBox(width: 8),
        Text(allOk ? '보정 성공' : '보정값 이상 — 다시 보정하세요',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: allOk ? Colors.green : Colors.red)),
      ]),
      const SizedBox(height: 8),
      InfoRow('scale (x y z)', f(sc), color: sc.every(scaleOk) ? null : Colors.red),
      InfoRow('bias (x y z)', f(b), color: b.every(biasOk) ? null : Colors.red),
      Text('기준: scale 0.9~1.1, bias ±1.0 m/s². 값은 드론에 자동 저장됩니다(약 1초 후).',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      if (allOk)
        Text('드론을 수평 바닥에 두고 왼쪽 "실시간 자세"에서 Roll/Pitch가 0° 근처인지 확인하세요.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
    ]);
  }

  // ---- IMU 정보 ----

  Widget _imuCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('IMU 정보', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('자이로 보정은 드론이 가만히 놓여 "착지"로 판단될 때 자동으로 됩니다.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
                onPressed: widget.s.link.connected ? _readImu : null,
                icon: const Icon(Icons.refresh),
                label: const Text('IMU 정보 읽기')),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.grey.shade100,
              child: SelectableText(_imuLines.isEmpty ? '-' : _imuLines.join('\n'),
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
            ),
          ]),
        ),
      );
}

/// 간단한 자세계: 하늘/땅 + 피치 눈금.
class _HorizonPainter extends CustomPainter {
  final double roll, pitch; // deg
  _HorizonPainter(this.roll, this.pitch);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-roll * math.pi / 180);
    final pxPerDeg = r / 45;
    canvas.translate(0, pitch * pxPerDeg);
    canvas.drawRect(Rect.fromLTRB(-2 * r, -3 * r, 2 * r, 0), Paint()..color = const Color(0xFF64B5F6));
    canvas.drawRect(Rect.fromLTRB(-2 * r, 0, 2 * r, 3 * r), Paint()..color = const Color(0xFFA1887F));
    final line = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(-2 * r, 0), Offset(2 * r, 0), line);
    for (var d = -30; d <= 30; d += 10) {
      if (d == 0) continue;
      final y = -d * pxPerDeg;
      canvas.drawLine(Offset(-r * 0.25, y), Offset(r * 0.25, y), line..strokeWidth = 1);
    }
    canvas.restore();
    // 기체 기준선
    final plane = Paint()
      ..color = Colors.orange
      ..strokeWidth = 4;
    canvas.drawLine(c + Offset(-r * 0.6, 0), c + Offset(-r * 0.15, 0), plane);
    canvas.drawLine(c + Offset(r * 0.15, 0), c + Offset(r * 0.6, 0), plane);
    canvas.drawCircle(c, 4, Paint()..color = Colors.orange);
    canvas.drawCircle(c, r, Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_HorizonPainter old) => old.roll != roll || old.pitch != pitch;
}
