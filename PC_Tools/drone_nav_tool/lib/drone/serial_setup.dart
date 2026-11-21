import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

class SerialPortEntry {
  final String name;
  final String description;
  SerialPortEntry(this.name, this.description);

  /// CH340/CP210x 등 USB-시리얼로 보이는 포트 (드론 DevKit 후보)
  bool get looksLikeUsb => RegExp(r'CH34|CP210|USB|UART', caseSensitive: false).hasMatch(description);
}

/// USB 시리얼로 드론 CLI에 명령을 보낸다 (115200 8N1, 시리얼 모니터와 같은 명령).
/// SerialPortReader는 쓰지 않는다: 그 isolate는 kill()이 비동기라 close 직후 포트를 해제하면
/// 해제된 메모리를 읽어 앱이 힙 손상(0xc0000374)으로 죽는다. 대신 메인 isolate에서 폴링한다.
class SerialSession {
  final SerialPort _port;
  Timer? _poll;
  final _out = StreamController<String>.broadcast();

  Stream<String> get output => _out.stream;

  SerialSession._(this._port);

  static List<SerialPortEntry> list() => [
        for (final name in SerialPort.availablePorts)
          () {
            final p = SerialPort(name);
            final d = p.description ?? '';
            p.dispose();
            return SerialPortEntry(name, d);
          }(),
      ];

  /// 포트를 연다. DevKit은 포트를 열 때 DTR/RTS로 리셋될 수 있으므로 호출 측에서 부팅을 기다린다.
  static SerialSession open(String name) {
    final port = SerialPort(name);
    if (!port.openReadWrite()) {
      final err = SerialPort.lastError;
      port.dispose();
      throw Exception('$name 포트를 열 수 없음 (다른 프로그램이 사용 중?): ${err?.message ?? ''}');
    }
    final cfg = SerialPortConfig()
      ..baudRate = 115200
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1
      ..setFlowControl(SerialPortFlowControl.none)
      ..dtr = SerialPortDtr.off
      ..rts = SerialPortRts.off;
    port.config = cfg;
    cfg.dispose();
    final s = SerialSession._(port);
    s._poll = Timer.periodic(const Duration(milliseconds: 50), (_) => s._read());
    return s;
  }

  void _read() {
    try {
      final n = _port.bytesAvailable;
      if (n > 0) _out.add(utf8.decode(_port.read(n), allowMalformed: true)); // timeout -1 = non-blocking
    } catch (e) {
      _out.add('\n[시리얼 오류] $e\n');
      _poll?.cancel();
    }
  }

  void sendLine(String line) => _port.write(Uint8List.fromList(utf8.encode('$line\n')));

  void close() {
    _poll?.cancel();
    _port.close();
    _port.dispose();
    _out.close();
  }
}
