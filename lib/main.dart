
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:battery_plus/battery_plus.dart';

import 'battery_details_page.dart';
import 'cpu_details_page.dart';
import 'services/battery_details_service.dart';
import 'services/gpu_usage_service.dart';
import 'services/hardware_service.dart';
import 'services/shizuku_service.dart';
import 'core/platform/hardware_channel.dart';

const _themePreference = 'themeMode';
const _languagePreference = 'language';
const _languageNames = {
  'zh': '繁體中文',
  'zh_Hans': '简体中文',
  'en': 'English',
  'ja': '日本語',
  'ko': '한국어',
};

const _traditionalChinese = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');

Locale? _appLocale(String? language) => switch (language) {
  'zh' => _traditionalChinese,
  'zh_Hans' => const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  'en' || 'ja' || 'ko' => Locale(language!),
  _ => null,
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = SharedPreferencesAsync();
  var mode = ThemeMode.system;
  String? language;
  try {
    final saved = await preferences.getString(_themePreference);
    mode = ThemeMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => ThemeMode.system,
    );
    language = await preferences.getString(_languagePreference);
  } catch (error) {
    debugPrint('Appearance preference: $error');
  }
  runApp(HardwareMonitorApp(initialThemeMode: mode, initialLanguage: language));
}

class HardwareMonitorApp extends StatefulWidget {
  const HardwareMonitorApp({
    super.key,
    this.initialThemeMode = ThemeMode.system,
    this.initialLanguage,
  });

  final ThemeMode initialThemeMode;
  final String? initialLanguage;

  @override
  State<HardwareMonitorApp> createState() => _HardwareMonitorAppState();
}

class _HardwareMonitorAppState extends State<HardwareMonitorApp> {
  late final _themeMode = ValueNotifier(widget.initialThemeMode);
  late final _language = ValueNotifier<String?>(
    _appLocale(widget.initialLanguage) == null ? null : widget.initialLanguage,
  );

  void _selectTheme(ThemeMode mode) {
    _themeMode.value = mode;
    unawaited(_savePreference(_themePreference, mode.name));
  }

  void _selectLanguage(String? language) {
    _language.value = language;
    unawaited(_savePreference(_languagePreference, language ?? ''));
  }

  Future<void> _savePreference(String key, String value) async {
    try {
      await SharedPreferencesAsync().setString(key, value);
    } catch (error) {
      debugPrint('Saving preference $key: $error');
    }
  }

  @override
  void dispose() {
    _themeMode.dispose();
    _language.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_themeMode, _language]),
      builder: (_, home) => MaterialApp(
        onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
        debugShowCheckedModeBanner: false,
        themeMode: _themeMode.value,
        locale: _appLocale(_language.value),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [
          _traditionalChinese,
          ...AppLocalizations.supportedLocales,
        ],
        localeListResolutionCallback: (preferred, supported) {
          final locales = preferred?.map((locale) {
            if (locale.languageCode != 'zh') return locale;
            final simplified = locale.scriptCode == 'Hans' ||
                (locale.scriptCode == null &&
                    const {'CN', 'SG', 'MY'}.contains(locale.countryCode));
            return _appLocale(simplified ? 'zh_Hans' : 'zh')!;
          }).toList();
          return basicLocaleListResolution(locales, supported);
        },
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: home,
      ),
      child: DashboardPage(
        themeMode: _themeMode,
        onThemeChanged: _selectTheme,
        language: _language,
        onLanguageChanged: _selectLanguage,
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: dark ? const Color(0xFF101616) : const Color(0xFFF3F5F4),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF08734E),
        brightness: brightness,
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xFF192221) : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.themeMode,
    required this.onThemeChanged,
    required this.language,
    required this.onLanguageChanged,
  });

  final ValueListenable<ThemeMode> themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueListenable<String?> language;
  final ValueChanged<String?> onLanguageChanged;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  AppLocalizations get l10n => AppLocalizations.of(context)!;
  final HardwareService _hardwareService = HardwareService();
  final HardwareChannel _nativeHardware = HardwareChannel();
  final ShizukuService _shizukuService = ShizukuService();
  late final _batteryDetailsService = BatteryDetailsService(
    _nativeHardware,
    _shizukuService,
  );
  late final GpuUsageService _gpuUsageService = GpuUsageService(_shizukuService);
  double? _gpuUsage;
  bool _samplingGpu = false;
  final Battery _battery = Battery();

  StreamSubscription<dynamic>? _batterySubscription;
  Map<String, dynamic> hardwareBattery = {};
  bool get _usesAndroidBatteryEvents =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Timer? _liveTimer;
  Timer? _shizukuStatusTimer;
  bool _readingNativeHardware = false;
  bool _readingNativeCpu = false;
  bool _readingTemperatures = false;

  Map<String, dynamic> _deviceInfo = {};
  Map<String, dynamic> _nativeInfo = {};
  Map<String, dynamic> _shizukuStatus = {};
  final _cpuSamples = ValueNotifier<Map<String, dynamic>>({});
  final _nativeCpu = ValueNotifier<Map<String, dynamic>>({});
  bool _samplingCpu = false;
  Map<String, dynamic> _temperatureInfo = {};

  bool _loading = true;
  int _selectedTab = 0;
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
          SnackBar(content: Text(l10n.newestVersion)),
        );
        return;
      }

      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.system_update, color: Colors.blueAccent),
              SizedBox(width: 8),
              Flexible(child: Text(l10n.updateAvailable)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.currentVersion(currentVersion)),
                const SizedBox(height: 6),
                Text(
                  l10n.latestVersion(latestVersion),
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.releaseNotes,
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  notes.isEmpty ? l10n.noReleaseNotes : notes,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                ),
                if (apkUrl == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      l10n.noApk,
                      style: TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.later),
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
              child: Text(apkUrl != null ? l10n.downloadUpdate : l10n.viewRelease),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('Update check error: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.updateError),
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
        builder: (settingsContext) {
          final l10n = AppLocalizations.of(settingsContext)!;
          return Scaffold(
          appBar: AppBar(
            title: Text(l10n.settings),
          ),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(
                  l10n.general,
                  style: TextStyle(
                    color: Theme.of(settingsContext).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ValueListenableBuilder<ThemeMode>(
                valueListenable: widget.themeMode,
                builder: (_, mode, _) => ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: Text(l10n.appearance),
                  trailing: DropdownButtonHideUnderline(
                    child: DropdownButton<ThemeMode>(
                      value: mode,
                      items: [
                        DropdownMenuItem(value: ThemeMode.light, child: Text(l10n.lightMode)),
                        DropdownMenuItem(value: ThemeMode.dark, child: Text(l10n.darkMode)),
                        DropdownMenuItem(value: ThemeMode.system, child: Text(l10n.followSystem)),
                      ],
                      onChanged: (mode) {
                        if (mode != null) widget.onThemeChanged(mode);
                      },
                    ),
                  ),
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: widget.language,
                builder: (context, language, _) => ListTile(
                  leading: const Icon(Icons.language),
                  title: Text(l10n.language),
                  subtitle: Text(_languageNames[language] ?? l10n.followSystem),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final selected = await showDialog<String>(
                      context: context,
                      builder: (dialogContext) => SimpleDialog(
                        title: Text(l10n.language),
                        children: [
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(dialogContext, ''),
                            child: Text(l10n.followSystem),
                          ),
                          for (final entry in _languageNames.entries)
                            SimpleDialogOption(
                              onPressed: () => Navigator.pop(dialogContext, entry.key),
                              child: Text(entry.value),
                            ),
                        ],
                      ),
                    );
                    if (mounted && selected != null) {
                      widget.onLanguageChanged(selected.isEmpty ? null : selected);
                    }
                  },
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.system_update_alt,
                  color: Colors.blueAccent,
                ),
                title: Text(l10n.checkUpdates),
                subtitle: Text(l10n.checkGithub),
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
          );
        },
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
    _loadNativeCpu();
    _refreshShizukuStatus();
    _loadShizukuCpu();
    _loadTemperatureSensors();

    _liveTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (timer) {
        if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
          return;
        }
        _loadNativeCpu();
        if (timer.tick % 2 == 0) {
          _loadShizukuCpu();
          _sampleGpuUsage();
        }
        if (timer.tick % 4 == 0) _loadNativeHardware();
        if (timer.tick % 10 == 0 && shizukuAuthorized) {
          _loadTemperatureSensors();
        }
      },
    );

    // Shizuku 狀態：每 5 秒重新檢查
    _shizukuStatusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
          _refreshShizukuStatus();
        }
      },
    );
  }

  @override
  void dispose() {
    _batterySubscription?.cancel();
    _liveTimer?.cancel();
    _shizukuStatusTimer?.cancel();
    _cpuSamples.dispose();
    _nativeCpu.dispose();
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
    if (_readingNativeHardware) return;
    _readingNativeHardware = true;
    try {
      final info = await _nativeHardware.getHardwareInfo(includeCpu: false);

      if (!mounted) return;

      setState(() {
        _nativeInfo = info;
      });
    } catch (e) {
      debugPrint('Native hardware error: $e');
    } finally {
      _readingNativeHardware = false;
    }
  }

  Future<void> _loadNativeCpu() async {
    if (_readingNativeCpu) return;
    _readingNativeCpu = true;
    try {
      final cpu = await _nativeHardware.getCpuInfo();
      if (!mounted) return;
      _nativeCpu.value = cpu;
    } catch (error) {
      debugPrint('Native CPU: $error');
    } finally {
      _readingNativeCpu = false;
    }
  }

  Future<void> _sampleGpuUsage() async {
    if (!mounted || !shizukuAuthorized || _samplingGpu) return;
    _samplingGpu = true;
    try {
      final usage = await _gpuUsageService.load();
      if (mounted && shizukuAuthorized && usage != _gpuUsage) {
        setState(() => _gpuUsage = usage);
      }
    } finally {
      _samplingGpu = false;
    }
  }

  Future<void> _refreshShizukuStatus() async {
    try {
      final status = await _shizukuService.getStatus();

      if (!mounted) return;

      final wasAuthorized = shizukuAuthorized;
      setState(() {
        _shizukuStatus = status;
        if (!shizukuAuthorized) _gpuUsage = null;
      });
      if (!wasAuthorized && shizukuAuthorized) _sampleGpuUsage();
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
    if (_samplingCpu) return;
    _samplingCpu = true;
    try {
      final result = await _shizukuService.getSystemCpuUsage();

      if (!mounted) return;

      _cpuSamples.value = result;
    } catch (e) {
      debugPrint('Shizuku CPU error: $e');

      if (mounted) {
        _cpuSamples.value = {
          'available': false,
          'reason': l10n.cpuError,
        };
      }
    } finally {
      _samplingCpu = false;
    }
  }

  Future<void> _loadTemperatureSensors() async {
    if (_readingTemperatures) return;
    _readingTemperatures = true;
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
            'reason': l10n.thermalError,
          };
        });
      }
    } finally {
      _readingTemperatures = false;
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
      await _loadNativeCpu();
      await _refreshShizukuStatus();
      await _sampleGpuUsage();
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

  Map<String, dynamic> get hardwareCpu => _nativeCpu.value;

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

  bool get thermalSensorsAvailable {
    return shizukuAuthorized &&
        _temperatureInfo['available'] == true &&
        _temperatureInfo['sensors'] is List &&
        (_temperatureInfo['sensors'] as List).isNotEmpty;
  }

  String get monitorMode {
    return shizukuAuthorized
        ? l10n.advancedMode
        : l10n.basicMode;
  }

  // --------------------------------------------------
  // CPU display with automatic fallback
  // --------------------------------------------------

  String get ramDisplay {
    final used = hardwareRam['usedMB'];

    if (used is num) {
      return '${(used / 1024).toStringAsFixed(1)} GB';
    }

    return '--';
  }

  String? _storageSize(String key) {
    final storage = _nativeInfo['storage'];
    final bytes = storage is Map ? storage[key] : null;
    if (bytes is! num || bytes < 0) return null;
    return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
  }

  String get thermalDisplay => switch (hardwareThermal['statusText']) {
    'Normal' => l10n.thermalNone,
    'Light' => l10n.thermalLight,
    'Moderate' => l10n.thermalModerate,
    'Severe' => l10n.thermalSevere,
    'Critical' => l10n.thermalCritical,
    'Emergency' => l10n.thermalEmergency,
    'Shutdown' => l10n.thermalShutdown,
    'Unsupported' => l10n.unsupported,
    _ => l10n.unknown,
  };

  // --------------------------------------------------
  // Battery status translation
  // --------------------------------------------------

  String get batteryStateText {
    final raw = hardwareBattery['status'];

    final state = raw?.toString().toLowerCase() ?? '';

    if (state == 'full' || state.endsWith('.full')) {
      return l10n.fullyCharged;
    }

    if (state == 'charging' ||
        state.endsWith('.charging')) {
      return l10n.charging;
    }

    if (state == 'discharging' ||
        state.endsWith('.discharging')) {
      return l10n.discharging;
    }

    if (state == 'notcharging' ||
        state == 'not charging' ||
        state.endsWith('.notcharging')) {
      return l10n.notCharging;
    }

    if (state.isEmpty ||
        state == 'unknown' ||
        state == 'null') {
      return l10n.unknown;
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
    VoidCallback? onTap,
  }) {
    final content = Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 21),
              const SizedBox(width: 7),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              if (onTap != null) const Icon(Icons.chevron_right, size: 18),
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
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
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
                  Text(
                    l10n.monitoringMode,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                        ? l10n.advancedEnabled
                        : l10n.basicDescription,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
      statusText = l10n.shizukuStopped;
    } else if (!shizukuAuthorized) {
      statusText = l10n.waitingPermission;
    } else {
      statusText = l10n.shizukuConnected;
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
                Expanded(
                  child: Text(
                    l10n.shizukuPermission,
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
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                      ? l10n.working
                      : l10n.requestPermission,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.shizukuOptional,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
        subtitle: Text(l10n.sensorCount(sensors.length)),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Text(
            l10n.temperatures,
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
              title: l10n.cpuTemp,
              value: _temperatureText(cpuTemp),
              subtitle: sensorsAvailable
                  ? 'CPU / CPU Cluster'
                  : l10n.requiresSensorAccess,
              icon: Icons.memory,
              color: Colors.orange,
            ),
            _buildMetricCard(
              title: l10n.gpuTemp,
              value: _temperatureText(gpuTemp),
              subtitle: sensorsAvailable
                  ? 'GPU Sensor'
                  : l10n.requiresSensorAccess,
              icon: Icons.developer_board,
              color: Colors.blue,
            ),
            _buildMetricCard(
              title: l10n.ddrTemp,
              value: _temperatureText(ddrTemp),
              subtitle: sensorsAvailable
                  ? l10n.memorySensors
                  : l10n.requiresSensorAccess,
              icon: Icons.storage,
              color: Colors.purple,
            ),
            _buildMetricCard(
              title: l10n.batteryTemp,
              value: _temperatureText(batteryTemp),
              subtitle: batteryTemp != null
                  ? 'Android BatteryManager'
                  : l10n.unavailable,
              icon: Icons.battery_charging_full,
              color: Colors.green,
            ),
          ],
        ),

        const SizedBox(height: 8),

        // Shizuku 感測器明細
        if (sensorsAvailable) ...[
          _buildTemperatureGroup(
            title: l10n.cpuSensors,
            category: 'cpu',
            icon: Icons.memory,
            color: Colors.orange,
          ),
          _buildTemperatureGroup(
            title: l10n.gpuSensors,
            category: 'gpu',
            icon: Icons.developer_board,
            color: Colors.blue,
          ),
          _buildTemperatureGroup(
            title: l10n.ddrSensors,
            category: 'ddr',
            icon: Icons.storage,
            color: Colors.purple,
          ),
          _buildTemperatureGroup(
            title: l10n.otherSensors,
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
                          ? l10n.sensorsUnavailable
                          : l10n.sensorsPermission,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            title: Text(l10n.androidThermal),
            subtitle: Text(
              l10n.thermalDescription,
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

    if (_compactLandscape) {
      return Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              Text(
                batteryPercent == null ? '—' : '${batteryPercent.toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(batteryStateText),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: progress, minHeight: 6),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Text(_temperatureText(_readDouble(temperature))),
            ],
          ),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.battery_full,
                    color: Colors.green,
                  ),
                  SizedBox(width: 8),
                  Text(
                    l10n.batteryInfo,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  Text(l10n.batteryLevel),
                  Text(
                    batteryPercent != null
                        ? '${batteryPercent.toStringAsFixed(0)}%'
                        : '--',
                    style: const TextStyle(
                fontSize: 32,
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
                  Text(l10n.batteryStatus),
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
                  Text(l10n.batteryTemp),
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
    );
  }

  // --------------------------------------------------
  // Device information
  // --------------------------------------------------

  Widget _systemCard(String title, Map<String, Object?> fields) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final entry in fields.entries)
              _infoRow(entry.key, entry.value?.toString().trim() ?? ''),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemPage() {
    final device = hardwareDevice;
    final gpu = hardwareGpu;
    final display = View.of(context).display;
    final ramMb = hardwareRam['totalMB'];
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView(
        key: const PageStorageKey('system'),
        physics: const AlwaysScrollableScrollPhysics(),
        dragStartBehavior: DragStartBehavior.down,
        padding: const EdgeInsets.all(12),
        children: [
          if (!_compactLandscape) Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (device['brand'] != null) Text(device['brand'].toString()),
                  Text(
                    (device['deviceName'] ?? _deviceInfo['deviceName'] ??
                        device['model'] ?? l10n.deviceInfo).toString(),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  if (device['androidVersion'] != null)
                    Text(device['androidVersion'].toString()),
                ],
              ),
            ),
          ),
          _adaptiveColumns(
            [
              _systemCard(l10n.deviceInfo, {
            l10n.deviceName: device['deviceName'] ?? _deviceInfo['deviceName'],
            l10n.brand: _deviceInfo['brand'] ?? device['brand'],
            l10n.manufacturer: _deviceInfo['manufacturer'] ?? device['brand'],
            l10n.model: device['model'] ?? _deviceInfo['model'],
            l10n.deviceCodename: _deviceInfo['device'],
            l10n.productCodename: _deviceInfo['product'],
          }),
          _systemCard(l10n.operatingSystem, {
            l10n.osVersion: device['androidVersion'] ?? _deviceInfo['osVersion'],
            if (device['androidSdk'] != null) 'Android SDK': device['androidSdk'],
            if (device['brand']?.toString().toLowerCase() == 'samsung')
              l10n.oneUiVersion: device['oneUiVersion'],
            l10n.securityPatch: _deviceInfo['securityPatch'],
            l10n.buildNumber: _deviceInfo['buildDisplay'],
            'Build ID': _deviceInfo['buildId'],
            'Bootloader': _deviceInfo['bootloader'],
          }),
            ],
            [
              ListenableBuilder(
            listenable: _nativeCpu,
            builder: (_, _) => _systemCard(l10n.hardwareSpecs, {
              l10n.socVendor: device['socManufacturer'],
              l10n.socModel: device['socModel'],
              l10n.cpuCores: hardwareCpu['cores'],
              l10n.supportedAbi: _deviceInfo['abis'],
              l10n.hardwarePlatform: _deviceInfo['hardware'],
              l10n.motherboard: _deviceInfo['board'],
              'GPU': gpu['renderer'],
              'OpenGL ES': gpu['version'],
              l10n.totalRam: ramMb is num
                  ? '${(ramMb / 1024).toStringAsFixed(1)} GB'
                  : null,
              l10n.totalStorage: _storageSize('totalBytes'),
            }),
          ),
          _systemCard(l10n.display, {
            l10n.resolution: '${display.size.width.round()} × ${display.size.height.round()}',
            l10n.refreshRate: '${display.refreshRate.toStringAsFixed(1)} Hz',
            l10n.pixelRatio: '${display.devicePixelRatio.toStringAsFixed(2)}×',
          }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              value.isEmpty ? '—' : value,
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

  Widget _adaptiveColumns(List<Widget> left, List<Widget> right) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < (_compactLandscape ? 500 : 580)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...left, ...right],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: left,
            )),
            const SizedBox(width: 8),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: right,
            )),
          ],
        );
      },
    );
  }

  Widget _buildPerformancePage() {
    final totalStorage = _storageSize('totalBytes');
    final ramMb = hardwareRam['totalMB'];
    final metricHeight = (_compactLandscape ? 62 : 86) +
        MediaQuery.textScalerOf(context).scale(54);
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView(
        key: const PageStorageKey('performance'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          _adaptiveColumns(
            [
              CpuDetailsPage(
                samples: _cpuSamples,
                nativeCpu: _nativeCpu,
                embedded: true,
              ),
            ],
            [
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: metricHeight,
                      child: _buildMetricCard(
                        title: l10n.gpuUsage,
                        value: !shizukuAuthorized || _gpuUsage == null
                            ? l10n.unavailable
                            : '${_gpuUsage!.toStringAsFixed(0)}%',
                        subtitle: shizukuAuthorized ? l10n.systemGpu : l10n.appGpu,
                        icon: Icons.developer_board,
                        color: Colors.blue,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: metricHeight,
                      child: _buildMetricCard(
                        title: l10n.ramUsed,
                        value: ramDisplay,
                        subtitle: ramMb is num
                            ? l10n.totalValue('${(ramMb / 1024).toStringAsFixed(1)} GB')
                            : l10n.memory,
                        icon: Icons.memory,
                        color: Colors.purple,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(
                height: metricHeight,
                child: _buildMetricCard(
                  title: l10n.storageUsed,
                  value: _storageSize('usedBytes') ?? l10n.unavailable,
                  subtitle: totalStorage == null
                      ? l10n.internalStorage
                      : l10n.totalValue(totalStorage),
                  icon: Icons.folder_outlined,
                  color: Colors.teal,
                ),
              ),
            ],
          ),
          _buildTemperatureCard(),
          _buildModeCard(),
          _buildShizukuCard(),
        ],
      ),
    );
  }

  bool get _compactLandscape {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 600 && size.width > size.height && size.height < 600;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final deviceName = hardwareDevice['deviceName'] ?? _deviceInfo['deviceName'];
    final theme = Theme.of(context);
    final page = switch (_selectedTab) {
      0 => _buildSystemPage(),
      1 => _buildPerformancePage(),
      _ => BatteryDetailsPage(
        service: _batteryDetailsService,
        summary: _buildBatteryCard(),
        compact: _compactLandscape,
      ),
    };
    final destinations = [
      (Icons.phone_android, l10n.systemTab),
      (Icons.speed_outlined, l10n.performanceTab),
      (Icons.battery_charging_full, l10n.batteryTab),
    ];
    final settings = IconButton(
      tooltip: l10n.settings,
      onPressed: _openSettings,
      icon: const Icon(Icons.settings_outlined),
    );
    if (_compactLandscape) {
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              NavigationRail(
                minWidth: 64,
                scrollable: true,
                selectedIndex: _selectedTab,
                onDestinationSelected: (index) =>
                    setState(() => _selectedTab = index),
                leading: settings,
                destinations: [
                  for (final (icon, label) in destinations)
                    NavigationRailDestination(
                      icon: Tooltip(message: label, child: Icon(icon)),
                      label: Text(label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: page),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: Icon(Icons.monitor_heart_outlined, color: theme.colorScheme.primary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.appTitle, style: theme.textTheme.titleMedium),
            if (deviceName != null)
              Text(deviceName.toString(), style: theme.textTheme.bodySmall),
          ],
        ),
        actions: [settings],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) => setState(() => _selectedTab = index),
        destinations: [
          for (final (icon, label) in destinations)
            NavigationDestination(icon: Icon(icon), label: label),
        ],
      ),
      body: SafeArea(bottom: false, child: page),
    );
  }
}
