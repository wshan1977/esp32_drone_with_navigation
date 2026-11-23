import 'dart:convert';
import 'dart:io';

/// %APPDATA%\DroneNavTool\settings.json 에 저장되는 사용자 설정.
class AppSettings {
  // LocationX
  bool cloud = false; // false = 내부망(서버 카드), true = 외부망 중계
  String serverIp = ''; // 서버 카드 IP (HTTP :8080)
  String brokerHost = ''; // 내부망 MQTT 브로커 (보통 서버 카드)
  int brokerPort = 1883;
  String cloudHost = '';
  int cloudPort = 1883;
  String siteId = '';

  String droneTagId = '';

  /// 수동 지정 드론 IP. 비어 있으면 하트비트 브로드캐스트로 자동 검색.
  String droneIp = '';
  String projectPath = '';

  /// 드론 기수 방향: false = ESP32 안테나 쪽, true = USB 쪽 (보정 참고 이미지 선택)
  bool noseAtUsb = false;

  /// 이륙할 때 드론 기수가 향한 지도 방향 (deg, +x=0, +y=90, 반시계 +). 위치 제어의 방향 기준
  double noseHeadingDeg = 0;

  static File get _file {
    final base = Platform.environment['APPDATA'] ?? Directory.current.path;
    return File('$base${Platform.pathSeparator}DroneNavTool${Platform.pathSeparator}settings.json');
  }

  static AppSettings load() {
    final s = AppSettings();
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      s.cloud = j['cloud'] == true;
      s.serverIp = j['serverIp'] as String? ?? '';
      s.brokerHost = j['brokerHost'] as String? ?? '';
      s.brokerPort = (j['brokerPort'] as num?)?.toInt() ?? 1883;
      s.cloudHost = j['cloudHost'] as String? ?? '';
      s.cloudPort = (j['cloudPort'] as num?)?.toInt() ?? 1883;
      s.siteId = j['siteId'] as String? ?? '';
      s.droneTagId = j['droneTagId'] as String? ?? '';
      s.droneIp = j['droneIp'] as String? ?? '';
      if (s.droneIp == '192.168.4.1') s.droneIp = ''; // 이전 버전의 AP 기본값 → 자동 검색
      s.projectPath = j['projectPath'] as String? ?? '';
      s.noseAtUsb = j['noseAtUsb'] == true;
      s.noseHeadingDeg = (j['noseHeadingDeg'] as num?)?.toDouble() ?? 0;
    } catch (_) {
      // 첫 실행 또는 손상된 파일 → 기본값
    }
    return s;
  }

  void save() {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'cloud': cloud,
        'serverIp': serverIp,
        'brokerHost': brokerHost,
        'brokerPort': brokerPort,
        'cloudHost': cloudHost,
        'cloudPort': cloudPort,
        'siteId': siteId,
        'droneTagId': droneTagId,
        'droneIp': droneIp,
        'projectPath': projectPath,
        'noseAtUsb': noseAtUsb,
        'noseHeadingDeg': noseHeadingDeg,
      }));
    } catch (_) {}
  }
}
