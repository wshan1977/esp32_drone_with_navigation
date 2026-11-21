import 'dart:typed_data';

import 'package:drone_nav_tool/mavlink/mavlink.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encoded frames parse back with valid CRC', () {
    final enc = MavEncoder();
    final parser = MavParser();
    final bytes = <int>[
      ...enc.heartbeat(),
      0x00, 0x13, // 쓰레기 바이트
      ...enc.serialControl('tof'),
      ...enc.commandLong(MavCmd.componentArmDisarm, params: [1]),
    ];
    final msgs = parser.feed(Uint8List.fromList(bytes));
    expect(msgs.map((m) => m.msgId), [MavId.heartbeat, MavId.serialControl, MavId.commandLong]);

    final sc = msgs[1];
    expect(sc.u8(8), 4); // count는 끝 NUL 포함
    expect(sc.str(9, 70), 'tof');
    expect(msgs[2].f32(0), 1.0);
    expect(msgs[2].u16(28), 400);
  });

  test('corrupted frame is rejected', () {
    final frame = MavEncoder().heartbeat();
    frame[frame.length - 1] ^= 0xff;
    expect(MavParser().feed(frame), isEmpty);
  });

  test('frame split across datagrams', () {
    final frame = MavEncoder().paramSet('ACC_BIAS_X', 0.5);
    final parser = MavParser();
    expect(parser.feed(frame.sublist(0, 7)), isEmpty);
    final msgs = parser.feed(frame.sublist(7));
    expect(msgs.single.str(6, 16), 'ACC_BIAS_X');
    expect(msgs.single.f32(0), 0.5);
  });
}
