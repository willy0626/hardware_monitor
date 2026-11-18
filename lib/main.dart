
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:battery_plus/battery_plus.dart';

import 'battery_details_page.dart';
import 'services/battery_details_service.dart';
import 'services/gpu_usage_service.dart';
import 'services/hardware_service.dart';
import 'services/shizuku_service.dart';
import 'core/platform/hardware_channel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HardwareMonitorApp());
}

class HardwareMonitorApp extends StatelessWidget {
  const HardwareMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '手機硬體監控',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF10131A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF1B202B),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final HardwareService _hardwareService = HardwareService();
  final HardwareChannel _nativeHardware = HardwareChannel();
  final ShizukuService _shizukuService = ShizukuService();
  late final GpuUsageService _gpuUsageService = GpuUsageService(_shizukuService);
  double? _gpuUsage;
  bool _samplingGpu = false;
  final Battery _battery = Battery();

  StreamSubscription<dynamic>? _batterySubscription;
  Map<String, dynamic> hardwareBattery = {};
  bool get _usesAndroidBatteryEvents =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Timer? _hardwareTimer;
  Timer? _cpuTimer;
  Timer? _temperatureTimer;
  Timer? _shizukuStatusTimer;

  Map<String, dynamic> _deviceInfo = {};
  Map<String, dynamic> _nativeInfo = {};
  Map<String, dynamic> _shizukuStatus = {};
  Map<String, dynamic> _shizukuCpu = {};
  Map<String, dynamic> _temperatureInfo = {};

  bool _loading = true;
  bool _requestingPermission = false;
  bool _refreshing = false;


  bool _checkingUpdate = false;

  static const String _githubApi =
      'https://api.github.com/repos/willy0626/hardware_monitor/releases/latest';

  int _compareVersions(String current, String latest) {
    List<int> parse(String value) {
      return value
          .replaceFirst(RegExp(r'^[vV]'), '')
          .split('+')[0]
          .split('.')
          .map((part) => int.tryParse(part) ?? 0)
          .toList();
    }

    final currentParts = parse(current);
    final latestParts = parse(latest);

    for (int i = 0; i < 3; i++) {
      final a = i < currentParts.length ? currentParts[i] : 0;
      final b = i < latestParts.length ? latestParts[i] : 0;

      if (a < b) return -1;
      if (a > b) return 1;
    }

    return 0;
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdate) return;

    setState(() => _checkingUpdate = true);

    try {
      final response = await http.get(
        Uri.parse(_githubApi),
        headers: {
          'Accept': 'application/vnd.github+json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('GitHub API 回應：${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = data['tag_name']?.toString() ?? '';
      final latestVersion = tag.replaceFirst(RegExp(r'^[vV]'), '');

      if (latestVersion.isEmpty) {
        throw Exception('GitHub Release 沒有設定版本標籤');
      }

      final releaseUrl = data['html_url']?.toString() ?? '';
      final notes = data['body']?.toString() ?? '';
      final assets = data['assets'] as List? ?? [];

      String? apkUrl;

      for (final asset in assets) {
        if (asset is Map &&
            asset['name']?.toString().toLowerCase().endsWith('.apk') == true) {
          apkUrl = asset['browser_download_url']?.toString();
          break;
        }
      }

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      if (!mounted) return;

      if (_compareVersions(currentVersion, latestVersion) >= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('目前已經是最新版！')),
        );
        return;
      }

      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.system_update, color: Colors.blueAccent),
              SizedBox(width: 8),
              Text('發現新版本'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('目前版本：$currentVersion'),
                const SizedBox(height: 6),
                Text(
                  '最新版本：$latestVersion',
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '更新內容',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  notes.isEmpty ? '沒有更新說明' : notes,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                ),
                if (apkUrl == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      '此版本尚未附上 APK，請前往 GitHub Release 頁面。',
                      style: TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('稍後'),
            ),
            FilledButton(
              onPressed: () async {
                final url = apkUrl ?? releaseUrl;
                final uri = Uri.tryParse(url);

                if (uri == null) return;

                Navigator.pop(dialogContext);

                await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
              },
              child: Text(apkUrl != null ? '下載更新' : '查看 Release'),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('Update check error: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('檢查更新失敗，請確認網路連線'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (settingsContext) => Scaffold(
          appBar: AppBar(
            title: const Text('設定'),
          ),
          body: ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(
                  '一般',
                  style: TextStyle(
                    color: Colors.white54,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.system_update_alt,
                  color: Colors.blueAccent,
                ),
                title: const Text('檢查更新'),
                subtitle: const Text('檢查 GitHub 是否有新版本'),
                trailing: _checkingUpdate
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: _checkingUpdate ? null : _checkForUpdates,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    _loadDeviceInfo();
    if (_usesAndroidBatteryEvents) {
      _batterySubscription = _nativeHardware.batteryUpdates.listen(
        _updateBatteryInfo,
        onError: (Object error) => debugPrint('Battery events: $error'),
      );
    } else {
      _loadBatteryInfo();
      _batterySubscription = _battery.onBatteryStateChanged.listen(
        (_) => _loadBatteryInfo(),
        onError: (Object error) => debugPrint('Battery events: $error'),
      );
    }
    _loadNativeHardware();
    _sampleGpuUsage();
    _refreshShizukuStatus();
    _loadShizukuCpu();
    _loadTemperatureSensors();

    // 原生硬體：每 2 秒更新
    _hardwareTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) {
        _loadNativeHardware();
        _sampleGpuUsage();
      },
    );

    // 全機 CPU：每 2 秒更新
    _cpuTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _loadShizukuCpu(),
    );

    // 溫度感測器：每 5 秒更新
    _temperatureTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _loadTemperatureSensors(),
    );

    // Shizuku 狀態：每 5 秒重新檢查
    _shizukuStatusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshShizukuStatus(),
    );
  }

  @override
  void dispose() {
    _batterySubscription?.cancel();
    _hardwareTimer?.cancel();
    _cpuTimer?.cancel();
    _temperatureTimer?.cancel();
    _shizukuStatusTimer?.cancel();
    super.dispose();
  }

  // --------------------------------------------------
  // Data loading
  // --------------------------------------------------

  Future<void> _loadDeviceInfo() async {
    try {
      final info = await _hardwareService.getDeviceInfo();

      if (!mounted) return;

      setState(() {
        _deviceInfo = info;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Device info error: $e');

      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadBatteryInfo() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;

      _updateBatteryInfo({
        'level': level >= 0 ? level : null,
        'status': state.toString(),
      });
    } catch (e) {
      debugPrint('Battery error: $e');
    }
  }

  void _updateBatteryInfo(Map<String, dynamic> info) {
    if (!mounted || mapEquals(hardwareBattery, info)) return;
    setState(() => hardwareBattery = info);
  }

  Future<void> _loadNativeHardware() async {
    try {
      final info = await _nativeHardware.getHardwareInfo();

      if (!mounted) return;

      setState(() {
        _nativeInfo = info;
      });
    } catch (e) {
      debugPrint('Native hardware error: $e');
    }
  }

  Future<void> _sampleGpuUsage() async {
    if (_samplingGpu) return;
    _samplingGpu = true;
    try {
      final usage = await _gpuUsageService.load();
      if (mounted && usage != _gpuUsage) setState(() => _gpuUsage = usage);
    } finally {
      _samplingGpu = false;
    }
  }

  Future<void> _refreshShizukuStatus() async {
    try {
      final status = await _shizukuService.getStatus();

      if (!mounted) return;

      setState(() {
        _shizukuStatus = status;
      });
    } catch (e) {
      debugPrint('Shizuku status error: $e');
    }
  }

  Future<void> _requestShizukuPermission() async {
    if (_requestingPermission) return;

    setState(() {
      _requestingPermission = true;
    });

    try {
      await _shizukuService.requestPermission();

      await _refreshShizukuStatus();
      await _loadShizukuCpu();
      await _loadTemperatureSensors();
    } catch (e) {
      debugPrint('Shizuku permission error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _requestingPermission = false;
        });
      }
    }
  }

  Future<void> _loadShizukuCpu() async {
    try {
      final result = await _shizukuService.getSystemCpuUsage();

      if (!mounted) return;

      setState(() {
        _shizukuCpu = result;
      });
    } catch (e) {
      debugPrint('Shizuku CPU error: $e');

      if (mounted) {
        setState(() {
          _shizukuCpu = {
            'available': false,
            'reason': 'CPU 讀取失敗',
          };
        });
      }
    }
  }

  Future<void> _loadTemperatureSensors() async {
    try {
      final result = await _shizukuService.getThermalSensors();

      if (!mounted) return;

      setState(() {
        _temperatureInfo = result;
      });
    } catch (e) {
      debugPrint('Thermal sensor error: $e');

      if (mounted) {
        setState(() {
          _temperatureInfo = {
            'available': false,
            'sensors': [],
            'reason': '溫度讀取失敗',
          };
        });
      }
    }
  }

  Future<void> _refreshAll() async {
    if (_refreshing) return;

    setState(() {
      _refreshing = true;
    });

    try {
      await _loadDeviceInfo();
      if (!_usesAndroidBatteryEvents) await _loadBatteryInfo();
      await _loadNativeHardware();
      await _sampleGpuUsage();
      await _refreshShizukuStatus();
      await _loadShizukuCpu();
      await _loadTemperatureSensors();
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
        });
      }
    }
  }

  // --------------------------------------------------
  // Hardware data getters
  // --------------------------------------------------

  Map<String, dynamic> get hardwareDevice {
    final device = _nativeInfo['device'];

    return device is Map
        ? Map<String, dynamic>.from(device)
        : {};
  }

  Map<String, dynamic> get hardwareCpu {
    final cpu = _nativeInfo['cpu'];

    return cpu is Map
        ? Map<String, dynamic>.from(cpu)
        : {};
  }

  Map<String, dynamic> get hardwareRam {
    final ram = _nativeInfo['ram'];

    return ram is Map
        ? Map<String, dynamic>.from(ram)
        : {};
  }

  Map<String, dynamic> get hardwareGpu {
    final gpu = _nativeInfo['gpu'];

    return gpu is Map
        ? Map<String, dynamic>.from(gpu)
        : {};
  }

  Map<String, dynamic> get hardwareThermal {
    final thermal = _nativeInfo['thermal'];

    return thermal is Map
        ? Map<String, dynamic>.from(thermal)
        : {};
  }

  bool get shizukuRunning {
    return _shizukuStatus['running'] == true;
  }

  bool get shizukuAuthorized {
    return shizukuRunning &&
        _shizukuStatus['permission'] == true;
  }

  bool get systemCpuAvailable {
    return shizukuAuthorized &&
        _shizukuCpu['available'] == true &&
        _shizukuCpu['usage'] is num;
  }

  bool get thermalSensorsAvailable {
    return shizukuAuthorized &&
        _temperatureInfo['available'] == true &&
        _temperatureInfo['sensors'] is List &&
        (_temperatureInfo['sensors'] as List).isNotEmpty;
  }

  String get monitorMode {
    return shizukuAuthorized
        ? '進階監控模式'
        : '一般監控模式';
  }

  // --------------------------------------------------
  // CPU display with automatic fallback
  // --------------------------------------------------

  String get cpuDisplay {
    // 優先使用 Shizuku 全機 CPU 使用率
    if (systemCpuAvailable) {
      final usage = _shizukuCpu['usage'] as num;

      return '${usage.toStringAsFixed(1)}%';
    }

    // Shizuku 不可用時，使用 Android 原生 API
    final appUsage = hardwareCpu['usage'];

    if (appUsage is num) {
      return '${appUsage.toStringAsFixed(1)}%';
    }

    return '--';
  }

  String get cpuSubtitle {
    if (systemCpuAvailable) {
      return '全機 CPU 使用率';
    }

    if (hardwareCpu['usage'] is num) {
      return 'App 本身 CPU 使用率';
    }

    return 'CPU 資料暫時無法取得';
  }

  // --------------------------------------------------
  // RAM / GPU / Thermal
  // --------------------------------------------------

  String get ramDisplay {
    final used = hardwareRam['usedMB'];

    if (used is num) {
      return '${(used / 1024).toStringAsFixed(1)} GB';
    }

    return '--';
  }

  String get gpuDisplay {
    final renderer = hardwareGpu['renderer'];

    if (renderer != null &&
        renderer.toString().isNotEmpty) {
      return renderer.toString();
    }

    return '讀取中';
  }

  String get thermalDisplay {
    return hardwareThermal['statusText']?.toString() ?? '未知';
  }

  // --------------------------------------------------
  // Battery status translation
  // --------------------------------------------------

  String get batteryStateText {
    final raw = hardwareBattery['status'];

    final state = raw?.toString().toLowerCase() ?? '';

    if (state == 'full' || state.endsWith('.full')) {
      return '已充滿';
    }

    if (state == 'charging' ||
        state.endsWith('.charging')) {
      return '充電中';
    }

    if (state == 'discharging' ||
        state.endsWith('.discharging')) {
      return '放電中';
    }

    if (state == 'notcharging' ||
        state == 'not charging' ||
        state.endsWith('.notcharging')) {
      return '未充電';
    }

    if (state.isEmpty ||
        state == 'unknown' ||
        state == 'null') {
      return '未知';
    }

    return raw.toString();
  }

  // --------------------------------------------------
  // Thermal sensor helpers
  // --------------------------------------------------

  List<Map<String, dynamic>> get thermalSensors {
    final raw = _temperatureInfo['sensors'];

    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  List<Map<String, dynamic>> _filterSensors(String category) {
    return thermalSensors.where((sensor) {
      final name = (sensor['name'] ?? '')
          .toString()
          .toLowerCase();

      switch (category) {
        case 'cpu':
          return name.startsWith('cpu-') ||
              name.startsWith('cpuss');

        case 'gpu':
          return name.startsWith('gpuss');

        case 'ddr':
          return name == 'ddr';

        case 'battery':
          return name == 'battery';

        default:
          return !name.startsWith('cpu-') &&
              !name.startsWith('cpuss') &&
              !name.startsWith('gpuss') &&
              name != 'ddr' &&
              name != 'battery';
      }
    }).toList();
  }

  double? _maxSensorTemperature(String category) {
    final sensors = _filterSensors(category);

    if (sensors.isEmpty) return null;

    final values = sensors
        .map((sensor) => sensor['temperatureC'])
        .whereType<num>()
        .map((value) => value.toDouble())
        .toList();

    if (values.isEmpty) return null;

    return values.reduce(
      (a, b) => a > b ? a : b,
    );
  }

  String _temperatureText(double? value) {
    if (value == null) return '--';

    return '${value.toStringAsFixed(1)}°C';
  }

  double? _readDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    return null;
  }

  // --------------------------------------------------
  // UI components
  // --------------------------------------------------

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 21),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------
  // Monitor mode card
  // --------------------------------------------------

  Widget _buildModeCard() {
    final advanced = shizukuAuthorized;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              advanced
                  ? Icons.speed
                  : Icons.phone_android,
              color: advanced
                  ? Colors.greenAccent
                  : Colors.blueAccent,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '目前監控模式',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    monitorMode,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: advanced
                          ? Colors.greenAccent
                          : Colors.blueAccent,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    advanced
                        ? '已啟用進階系統資料讀取'
                        : '基本硬體監控不需要 Shizuku',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              advanced
                  ? Icons.check_circle
                  : Icons.info_outline,
              color: advanced
                  ? Colors.green
                  : Colors.blueAccent,
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------
  // Shizuku card
  // --------------------------------------------------

  Widget _buildShizukuCard() {
    final running = shizukuRunning;

    String statusText;

    if (!running) {
      statusText = 'Shizuku 未啟動';
    } else if (!shizukuAuthorized) {
      statusText = '等待授權';
    } else {
      statusText = '已連線並取得授權';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.security,
                  color: Colors.blueAccent,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Shizuku 系統權限',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(
                  shizukuAuthorized
                      ? Icons.check_circle
                      : Icons.info,
                  color: shizukuAuthorized
                      ? Colors.green
                      : Colors.orange,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              statusText,
              style: const TextStyle(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _requestingPermission
                    ? null
                    : _requestShizukuPermission,
                icon: _requestingPermission
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.verified_user),
                label: Text(
                  _requestingPermission
                      ? '處理中...'
                      : '檢查 / 請求 Shizuku 授權',
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Shizuku 是選用的進階功能。沒有啟動時，基本監控仍然可以使用。',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------
  // Temperature sensor group
  // --------------------------------------------------

  Widget _buildTemperatureGroup({
    required String title,
    required String category,
    required IconData icon,
    required Color color,
  }) {
    final sensors = _filterSensors(category);
    final maxTemp = _maxSensorTemperature(category);

    if (sensors.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text('${sensors.length} 個感測器'),
        trailing: Text(
          _temperatureText(maxTemp),
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        children: sensors.map((sensor) {
          final name =
              sensor['name']?.toString() ?? 'Unknown';

          final temperature = sensor['temperatureC'];

          return ListTile(
            dense: true,
            title: Text(
              name,
              style: const TextStyle(fontSize: 13),
            ),
            trailing: Text(
              temperature is num
                  ? _temperatureText(
                      temperature.toDouble(),
                    )
                  : '--',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // --------------------------------------------------
  // Temperature card
  // --------------------------------------------------

  Widget _buildTemperatureCard() {
    final cpuTemp = _maxSensorTemperature('cpu');
    final gpuTemp = _maxSensorTemperature('gpu');
    final ddrTemp = _maxSensorTemperature('ddr');

    final batterySensors = _filterSensors('battery');

    // 優先使用 Shizuku 電池感測器
    // 沒有時使用 Android BatteryManager
    final batteryTemp = batterySensors.isNotEmpty
        ? _readDouble(
            batterySensors.first['temperatureC'],
          )
        : _readDouble(
            hardwareBattery['temperatureC'],
          );

    final sensorsAvailable = thermalSensorsAvailable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Text(
            '溫度監控',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),

        // 不論有沒有 Shizuku，都顯示基本溫度卡片
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.3,
          children: [
            _buildMetricCard(
              title: 'CPU 溫度',
              value: _temperatureText(cpuTemp),
              subtitle: sensorsAvailable
                  ? 'CPU / CPU Cluster'
                  : '需要進階感測器權限',
              icon: Icons.memory,
              color: Colors.orange,
            ),
            _buildMetricCard(
              title: 'GPU 溫度',
              value: _temperatureText(gpuTemp),
              subtitle: sensorsAvailable
                  ? 'GPU Sensor'
                  : '需要進階感測器權限',
              icon: Icons.developer_board,
              color: Colors.blue,
            ),
            _buildMetricCard(
              title: 'DDR 溫度',
              value: _temperatureText(ddrTemp),
              subtitle: sensorsAvailable
                  ? '記憶體感測器'
                  : '需要進階感測器權限',
              icon: Icons.storage,
              color: Colors.purple,
            ),
            _buildMetricCard(
              title: '電池溫度',
              value: _temperatureText(batteryTemp),
              subtitle: batteryTemp != null
                  ? 'Android BatteryManager'
                  : '目前無法讀取',
              icon: Icons.battery_charging_full,
              color: Colors.green,
            ),
          ],
        ),

        const SizedBox(height: 8),

        // Shizuku 感測器明細
        if (sensorsAvailable) ...[
          _buildTemperatureGroup(
            title: 'CPU 感測器',
            category: 'cpu',
            icon: Icons.memory,
            color: Colors.orange,
          ),
          _buildTemperatureGroup(
            title: 'GPU 感測器',
            category: 'gpu',
            icon: Icons.developer_board,
            color: Colors.blue,
          ),
          _buildTemperatureGroup(
            title: 'DDR 感測器',
            category: 'ddr',
            icon: Icons.storage,
            color: Colors.purple,
          ),
          _buildTemperatureGroup(
            title: '其他感測器',
            category: 'other',
            icon: Icons.thermostat,
            color: Colors.teal,
          ),
        ] else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    color: Colors.orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      shizukuAuthorized
                          ? (_temperatureInfo['reason']
                                  ?.toString() ??
                              '目前無法讀取進階溫度感測器')
                          : 'CPU、GPU、DDR 等詳細感測器需要 Shizuku 授權。電池溫度仍可獨立讀取。',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        const SizedBox(height: 10),

        // Android 原生系統溫控
        Card(
          child: ListTile(
            leading: const Icon(
              Icons.thermostat_auto,
              color: Colors.cyan,
            ),
            title: const Text('Android 系統溫控狀態'),
            subtitle: const Text(
              '這是系統熱狀態等級，不是實際溫度。',
              style: TextStyle(fontSize: 11),
            ),
            trailing: Text(
              thermalDisplay,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.cyan,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------
  // Battery card
  // --------------------------------------------------

  Widget _buildBatteryCard() {
    final level = hardwareBattery['level'];

    final temperature = hardwareBattery['temperatureC'];

    final double? batteryPercent = _readDouble(level);

    final double progress = batteryPercent == null
        ? 0
        : (batteryPercent / 100).clamp(0.0, 1.0);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => BatteryDetailsPage(
              service: BatteryDetailsService(_nativeHardware, _shizukuService),
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.battery_full,
                    color: Colors.green,
                  ),
                  SizedBox(width: 8),
                  Text(
                    '電池資訊',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Spacer(),
                  Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  const Text('電量'),
                  Text(
                    batteryPercent != null
                        ? '${batteryPercent.toStringAsFixed(0)}%'
                        : '--',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  const Text('電池狀態'),
                  Text(
                    batteryStateText,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  const Text('電池溫度'),
                  Text(
                    temperature is num
                        ? '${temperature.toStringAsFixed(1)}°C'
                        : '--',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------
  // Device information
  // --------------------------------------------------

  Widget _buildDeviceInfoCard() {
    final brand = hardwareDevice['brand'] ??
        _deviceInfo['brand'] ??
        _deviceInfo['manufacturer'] ??
        '未知';

    final model = hardwareDevice['model'] ??
        _deviceInfo['model'] ??
        '未知';

    final deviceName = hardwareDevice['deviceName'];

    final androidVersion =
        hardwareDevice['androidVersion'] ??
            _deviceInfo['androidVersion'] ??
            _deviceInfo['version'] ??
            '未知';

    final oneUiVersion =
        hardwareDevice['oneUiVersion'] ?? '無法讀取';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            const Text(
              '裝置資訊',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _infoRow('品牌', brand.toString()),
            _infoRow('型號', model.toString()),
            if (deviceName != null &&
                deviceName.toString().isNotEmpty)
              _infoRow(
                '裝置名稱',
                deviceName.toString(),
              ),
            _infoRow(
              'Android 版本',
              androidVersion.toString(),
            ),
            _infoRow(
              'One UI 版本',
              oneUiVersion.toString(),
            ),
            _infoRow(
              'CPU 核心數',
              hardwareCpu['cores']?.toString() ?? '--',
            ),
            _infoRow('GPU', gpuDisplay),
            _infoRow(
              'RAM 總容量',
              hardwareRam['totalMB'] is num
                  ? '${((hardwareRam['totalMB'] as num) / 1024).toStringAsFixed(1)} GB'
                  : '--',
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 115,
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: const TextStyle(
                color: Colors.white54,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------
  // Main dashboard
  // --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('手機硬體監控'),
        actions: [
          IconButton(
            tooltip: '設定',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _buildDeviceInfoCard(),

            const SizedBox(height: 10),

            _buildModeCard(),

            const SizedBox(height: 10),

            _buildShizukuCard(),

            const SizedBox(height: 10),

            const Text(
              '硬體即時監控',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics:
                  const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.3,
              children: [
                _buildMetricCard(
                  title: 'CPU 使用率',
                  value: cpuDisplay,
                  subtitle: cpuSubtitle,
                  icon: Icons.memory,
                  color: Colors.orange,
                ),
                _buildMetricCard(
                  title: 'RAM 已使用',
                  value: ramDisplay,
                  subtitle:
                      hardwareRam['totalMB'] is num
                          ? '總共 ${((hardwareRam['totalMB'] as num) / 1024).toStringAsFixed(1)} GB'
                          : '記憶體',
                  icon: Icons.storage,
                  color: Colors.purple,
                ),
                _buildMetricCard(
                  title: 'GPU 使用率',
                  value: _gpuUsage == null
                      ? '無法取得'
                      : '${_gpuUsage!.toStringAsFixed(0)}%',
                  subtitle: hardwareGpu['renderer']?.toString() ?? 'GPU',
                  icon: Icons.developer_board,
                  color: Colors.blue,
                ),
                _buildMetricCard(
                  title: '系統溫控',
                  value: thermalDisplay,
                  subtitle: 'Android Thermal Status',
                  icon: Icons.thermostat,
                  color: Colors.cyan,
                ),
              ],
            ),

            const SizedBox(height: 10),

            _buildBatteryCard(),

            const SizedBox(height: 10),

            _buildTemperatureCard(),

            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}
