import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../aoa/aoa_client.dart';
import '../aoa/floor_plan.dart';
import '../aoa/locationx_api.dart';
import '../drone/drone_link.dart';
import 'settings.dart';

/// 앱 전체가 공유하는 연결·상태.
class AppServices {
  final AppSettings settings = AppSettings.load();
  final DroneLink link = DroneLink();
  final AoaClient aoa = AoaClient();
  final ValueNotifier<FloorPlan?> plan = ValueNotifier(null);

  /// 지도에서 지정한 목표점 (world m).
  final ValueNotifier<Offset?> target = ValueNotifier(null);

  Future<void> start() async {
    link.setManualAddress(settings.droneIp);
    await link.start();
    if (settings.projectPath.isNotEmpty) {
      try {
        plan.value = await FloorPlan.load(settings.projectPath);
      } catch (_) {}
    }
    try {
      if (settings.cloud && settings.cloudHost.isNotEmpty && settings.siteId.isNotEmpty) {
        await connectCloud();
      } else if (!settings.cloud && settings.serverIp.isNotEmpty) {
        await connectLan(settings.serverIp, brokerHost: settings.brokerHost);
      }
    } catch (_) {
      // 시작 시 자동 연결 실패는 상단 상태로만 보인다
    }
  }

  /// 내부망: 서버 카드에서 토픽 루트·로케이터·외부망 정보를 읽고 MQTT에 연결한다.
  /// 서버 카드 HTTP가 안 되면 기본 루트(controlbit)로 MQTT만 연결하고 예외를 다시 던진다.
  Future<void> connectLan(String serverIp, {String brokerHost = ''}) async {
    settings
      ..cloud = false
      ..serverIp = serverIp.trim()
      ..brokerHost = brokerHost.trim().isEmpty ? serverIp.trim() : brokerHost.trim();
    settings.save();
    LxServerInfo? info;
    Object? httpError;
    try {
      info = await LocationXApi.fetchServerInfo(settings.serverIp);
      // 외부망 정보는 다음에 외부망으로 접속할 때 쓰도록 저장
      if (info.siteId.isNotEmpty) {
        settings
          ..siteId = info.siteId
          ..cloudHost = info.cloudHost
          ..cloudPort = info.cloudPort;
        settings.save();
      }
    } catch (e) {
      httpError = e;
    }
    await aoa.connectLan(settings.brokerHost,
        brokerPort: settings.brokerPort,
        root: info?.topicRoot ?? 'controlbit',
        locators: info?.locators ?? const []);
    if (httpError != null) throw Exception('서버 카드 정보(:8080)를 읽지 못함: $httpError');
  }

  Future<void> connectCloud() async {
    settings.cloud = true;
    settings.save();
    await aoa.connectCloud(settings.cloudHost, brokerPort: settings.cloudPort, site: settings.siteId);
  }
}
