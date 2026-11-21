import 'dart:convert';
import 'dart:typed_data';

/// 이 도구가 쓰는 메시지만 담은 최소 MAVLink v1/v2 코덱.
/// 레이아웃·CRC_EXTRA는 펌웨어가 쓰는 okalachev/MAVLink 2.0.35 헤더(common/minimal)에서 가져왔다.
class MavId {
  static const heartbeat = 0;
  static const sysStatus = 1;
  static const paramRequestList = 21;
  static const paramValue = 22;
  static const paramSet = 23;
  static const scaledImu = 26;
  static const attitudeQuaternion = 31;
  static const manualControl = 69;
  static const commandLong = 76;
  static const commandAck = 77;
  static const setAttitudeTarget = 82;
  static const setPositionTargetLocalNed = 84;
  static const serialControl = 126;
  static const distanceSensor = 132;
  static const extendedSysState = 245;
  static const namedValueFloat = 251;
  static const statusText = 253;
}

/// msgId → (CRC_EXTRA, 전체 payload 길이)
const Map<int, (int, int)> _msgInfo = {
  MavId.heartbeat: (50, 9),
  MavId.sysStatus: (124, 43),
  MavId.paramRequestList: (159, 2),
  MavId.paramValue: (220, 25),
  MavId.paramSet: (168, 23),
  MavId.scaledImu: (170, 24),
  MavId.attitudeQuaternion: (246, 48),
  MavId.manualControl: (243, 30),
  MavId.commandLong: (152, 33),
  MavId.commandAck: (143, 10),
  MavId.setAttitudeTarget: (49, 51),
  MavId.setPositionTargetLocalNed: (143, 53),
  MavId.serialControl: (220, 81),
  MavId.distanceSensor: (85, 39),
  MavId.extendedSysState: (130, 2),
  MavId.namedValueFloat: (170, 18),
  MavId.statusText: (83, 54),
};

class MavCmd {
  static const navLand = 21;
  static const navTakeoff = 22;
  static const doSetMode = 176;
  static const componentArmDisarm = 400;
}

int _crcAccumulate(int b, int crc) {
  var tmp = (b ^ (crc & 0xff)) & 0xff;
  tmp = (tmp ^ (tmp << 4)) & 0xff;
  return ((crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)) & 0xffff;
}

class MavMessage {
  final int msgId;
  final int sysId;
  final int compId;

  /// 전체 길이로 0 채움된 payload (v2의 뒤쪽 0 잘림 복원).
  final ByteData p;

  MavMessage(this.msgId, this.sysId, this.compId, this.p);

  int u8(int o) => p.getUint8(o);
  int i16(int o) => p.getInt16(o, Endian.little);
  int u16(int o) => p.getUint16(o, Endian.little);
  int u32(int o) => p.getUint32(o, Endian.little);
  double f32(int o) => p.getFloat32(o, Endian.little);

  String str(int o, int len) {
    final bytes = <int>[];
    for (var i = 0; i < len; i++) {
      final b = p.getUint8(o + i);
      if (b == 0) break;
      bytes.add(b);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// 바이트 스트림 → 메시지. CRC가 틀리거나 모르는 메시지는 버린다.
class MavParser {
  final List<int> _buf = [];

  List<MavMessage> feed(Uint8List data) {
    _buf.addAll(data);
    final out = <MavMessage>[];
    while (true) {
      final start = _buf.indexWhere((b) => b == 0xFD || b == 0xFE);
      if (start < 0) {
        _buf.clear();
        break;
      }
      if (start > 0) _buf.removeRange(0, start);
      if (_buf.length < 2) break;

      final v2 = _buf[0] == 0xFD;
      final len = _buf[1];
      final headerLen = v2 ? 10 : 6;
      final sigLen = v2 && _buf.length > 2 && (_buf[2] & 0x01) != 0 ? 13 : 0;
      final frameLen = headerLen + len + 2 + sigLen;
      if (_buf.length < frameLen) break;

      final msgId = v2 ? (_buf[7] | (_buf[8] << 8) | (_buf[9] << 16)) : _buf[5];
      final info = _msgInfo[msgId];
      var crc = 0xffff;
      for (var i = 1; i < headerLen + len; i++) {
        crc = _crcAccumulate(_buf[i], crc);
      }
      final rxCrc = _buf[headerLen + len] | (_buf[headerLen + len + 1] << 8);
      if (info != null) crc = _crcAccumulate(info.$1, crc);

      if (info == null || crc != rxCrc) {
        _buf.removeAt(0); // 다음 시작 바이트부터 다시 찾는다
        continue;
      }
      final payload = Uint8List(len > info.$2 ? len : info.$2)
        ..setRange(0, len, _buf, headerLen);
      final sysId = v2 ? _buf[5] : _buf[3];
      final compId = v2 ? _buf[6] : _buf[4];
      out.add(MavMessage(msgId, sysId, compId, ByteData.sublistView(payload)));
      _buf.removeRange(0, frameLen);
    }
    return out;
  }
}

/// MAVLink v2 프레임 생성 (GCS: sysid 255, compid 190).
class MavEncoder {
  final int sysId;
  final int compId;
  int _seq = 0;

  MavEncoder({this.sysId = 255, this.compId = 190});

  Uint8List frame(int msgId, ByteData payload) {
    final info = _msgInfo[msgId]!;
    var bytes = payload.buffer.asUint8List(payload.offsetInBytes, info.$2);
    var len = bytes.length;
    while (len > 1 && bytes[len - 1] == 0) {
      len--; // v2 뒤쪽 0 잘림
    }
    final out = Uint8List(10 + len + 2);
    out[0] = 0xFD;
    out[1] = len;
    out[2] = 0;
    out[3] = 0;
    out[4] = _seq++ & 0xff;
    out[5] = sysId;
    out[6] = compId;
    out[7] = msgId & 0xff;
    out[8] = (msgId >> 8) & 0xff;
    out[9] = (msgId >> 16) & 0xff;
    out.setRange(10, 10 + len, bytes);
    var crc = 0xffff;
    for (var i = 1; i < 10 + len; i++) {
      crc = _crcAccumulate(out[i], crc);
    }
    crc = _crcAccumulate(info.$1, crc);
    out[10 + len] = crc & 0xff;
    out[11 + len] = crc >> 8;
    return out;
  }

  ByteData _payload(int msgId) => ByteData(_msgInfo[msgId]!.$2);

  Uint8List heartbeat() {
    final p = _payload(MavId.heartbeat)
      ..setUint8(4, 6) // MAV_TYPE_GCS
      ..setUint8(5, 8) // MAV_AUTOPILOT_INVALID
      ..setUint8(7, 4) // MAV_STATE_ACTIVE
      ..setUint8(8, 3);
    return frame(MavId.heartbeat, p);
  }

  Uint8List commandLong(int command, {List<double> params = const [], int target = 1}) {
    final p = _payload(MavId.commandLong);
    for (var i = 0; i < 7; i++) {
      p.setFloat32(i * 4, i < params.length ? params[i] : 0, Endian.little);
    }
    p
      ..setUint16(28, command, Endian.little)
      ..setUint8(30, target)
      ..setUint8(31, 1);
    return frame(MavId.commandLong, p);
  }

  Uint8List paramRequestList({int target = 1}) {
    final p = _payload(MavId.paramRequestList)..setUint8(0, target);
    return frame(MavId.paramRequestList, p);
  }

  Uint8List paramSet(String name, double value, {int target = 1}) {
    final p = _payload(MavId.paramSet)
      ..setFloat32(0, value, Endian.little)
      ..setUint8(4, target)
      ..setUint8(5, 1)
      ..setUint8(22, 9); // MAV_PARAM_TYPE_REAL32
    final id = ascii.encode(name);
    for (var i = 0; i < id.length && i < 16; i++) {
      p.setUint8(6 + i, id[i]);
    }
    return frame(MavId.paramSet, p);
  }

  /// 목표 고도 (m, 위 +). 펌웨어는 z(NED, 아래 +)만 쓰므로 나머지 필드는 무시 비트를 세운다.
  Uint8List setAltitude(double height, {int target = 1}) {
    final p = _payload(MavId.setPositionTargetLocalNed)
      ..setFloat32(12, -height, Endian.little)
      ..setUint16(48, 0xFFF & ~4, Endian.little) // z 외 모두 ignore
      ..setUint8(50, target)
      ..setUint8(51, 1)
      ..setUint8(52, 1); // MAV_FRAME_LOCAL_NED
    return frame(MavId.setPositionTargetLocalNed, p);
  }

  /// 펌웨어 CLI 명령. 펌웨어가 strlcpy(data, m.data, m.count)로 복사하므로
  /// count에 끝 NUL을 포함해야 마지막 글자가 잘리지 않는다.
  Uint8List serialControl(String text, {int target = 1}) {
    final data = utf8.encode(text);
    final n = data.length > 69 ? 69 : data.length;
    final p = _payload(MavId.serialControl)
      ..setUint8(6, 10) // SERIAL_CONTROL_DEV_SHELL
      ..setUint8(7, 2) // SERIAL_CONTROL_FLAG_RESPOND
      ..setUint8(8, n + 1)
      ..setUint8(79, target)
      ..setUint8(80, 1);
    for (var i = 0; i < n; i++) {
      p.setUint8(9 + i, data[i]);
    }
    return frame(MavId.serialControl, p);
  }
}
