import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/services.dart';
import 'ui/calibration_page.dart';
import 'ui/console_page.dart';
import 'ui/drone_dialog.dart';
import 'ui/flight_page.dart';
import 'ui/params_page.dart';
import 'ui/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices();
  services.start();
  runApp(DroneNavApp(s: services));
}

class DroneNavApp extends StatelessWidget {
  final AppServices s;
  const DroneNavApp({super.key, required this.s});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drone Nav Tool',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1565C0),
        useMaterial3: true,
        fontFamily: 'Malgun Gothic',
      ),
      home: HomePage(s: s),
    );
  }
}

class HomePage extends StatefulWidget {
  final AppServices s;
  const HomePage({super.key, required this.s});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  AppServices get s => widget.s;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Space = 비상정지 (텍스트 입력 중에는 제외).
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.space) return false;
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    if (focused is EditableText) return false;
    _estop();
    return true;
  }

  void _estop() {
    s.link.emergencyStop();
    showSnack(context, '비상정지: 시동 해제 명령을 보냈습니다');
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      FlightPage(s: s),
      CalibrationPage(s: s),
      ConsolePage(s: s),
      ParamsPage(s: s),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drone Nav Tool'),
        actions: [
          ListenableBuilder(
            listenable: s.link,
            builder: (context, _) {
              final l = s.link;
              return Row(children: [
                if (l.bindError.isNotEmpty)
                  Tooltip(message: l.bindError, child: const Icon(Icons.warning, color: Colors.orange)),
                TextButton.icon(
                  onPressed: () => DroneDialog.show(context, s),
                  icon: Icon(Icons.circle, size: 12, color: l.connected ? Colors.green : Colors.grey),
                  label: Text(l.connected
                      ? '드론 ${l.droneAddress?.address} · ${l.armed ? "시동 ON" : "시동 OFF"} · ${l.mode?.label ?? "-"}'
                          '${l.batteryV == null ? "" : " · ${l.batteryV!.toStringAsFixed(2)}V"}'
                      : '드론 찾는 중… (클릭: 연결 설정)'),
                ),
              ]);
            },
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: _estop,
            icon: const Icon(Icons.dangerous),
            label: const Text('비상정지 (Space)'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(children: [
        NavigationRail(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          labelType: NavigationRailLabelType.all,
          destinations: const [
            NavigationRailDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: Text('비행')),
            NavigationRailDestination(icon: Icon(Icons.tune), label: Text('보정')),
            NavigationRailDestination(icon: Icon(Icons.terminal), label: Text('콘솔')),
            NavigationRailDestination(icon: Icon(Icons.list_alt), label: Text('파라미터')),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(child: IndexedStack(index: _tab, children: pages)),
      ]),
    );
  }
}
