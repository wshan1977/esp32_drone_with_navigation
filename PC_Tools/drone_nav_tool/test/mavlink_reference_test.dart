import 'package:drone_nav_tool/mavlink/mavlink.dart';
import 'package:flutter_test/flutter_test.dart';

/// 펌웨어와 같은 MAVLink C 라이브러리(okalachev/MAVLink 2.0.35)의 mavlink_msg_*_pack으로
/// 만든 기준 프레임 (sysid 255 / compid 190, seq 0부터).
const _reference = [
  'fd09000000ffbe0000000000000006080004033d48',
  'fd51000001ffbe7e00000000000000000a0204746f66000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000101c34f',
  'fd20000002ffbe4c00000000803f0000000000000000000000000000000000000000000000009001010142db',
  'fd17000003ffbe1700000000003f01014143435f424941535f58000000000000094a53',
  'fd35000004ffbe540000000000000000000000000000cdcc4cbf0000000000000000000000000000000000000000000000000000000000000000fb0f010101a4f7',
  'fd20000005ffbe4c0000000000000000000000000000000000000000000000000000cdcc4c3f160001016ae4',
  'fd0b000006ffbe450000000000005e01000000000114ea',
];

String _hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('encoder matches the C library byte for byte', () {
    final enc = MavEncoder();
    final frames = [
      enc.heartbeat(),
      enc.serialControl('tof'),
      enc.commandLong(MavCmd.componentArmDisarm, params: [1]),
      enc.paramSet('ACC_BIAS_X', 0.5),
      enc.setAltitude(0.8),
      enc.commandLong(MavCmd.navTakeoff, params: [0, 0, 0, 0, 0, 0, 0.8]),
      enc.manualControl(throttle: 0.35),
    ];
    for (var i = 0; i < frames.length; i++) {
      expect(_hex(frames[i]), _reference[i], reason: 'frame $i');
    }
  });
}
