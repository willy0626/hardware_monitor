
import 'dart:io';

import 'package:shizuku_api_plugin/shizuku_api.dart';
import 'package:flutter/foundation.dart';

class ShizukuService {
  final ShizukuApi _api = ShizukuApi();

  Future<String?> readBatteryDetails(String command) => readSystemData(command);

  Future<String?> readSystemData(String command) async {
    final status = await getStatus();
    if (status['permission'] != true) return null;
    return _api.runCommand(command);
  }

  final _cpuBaseline = <int, ({int total, int idle})>{};
  static final _cpuLine = RegExp(r'^cpu(\d*)\s+');

  /// 檢查 Shizuku 狀態
  Future<Map<String, dynamic>> getStatus() async {
    try {
      final running = await _api.pingBinder() ?? false;

      if (!running) {
        return {
          'running': false,
          'permission': false,
          'status': 'Shizuku 未啟動',
        };
      }

      final permission = await _api.checkPermission() ?? false;

      return {
        'running': true,
        'permission': permission,
        'status': permission ? '已授權' : '等待授權',
      };
    } catch (e) {
      return {
        'running': false,
        'permission': false,
        'status': '檢查失敗：$e',
      };
    }
  }

  /// 請求 Shizuku 授權
  Future<bool> requestPermission() async {
    try {
      final running = await _api.pingBinder() ?? false;

      if (!running) return false;

      return await _api.requestPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 讀取全機 CPU 使用率
  Future<Map<String, dynamic>> getSystemCpuUsage() async {
    try {
      String? output;
      var source = '系統 /proc/stat';
      if (!kIsWeb && Platform.isAndroid) {
        try {
          output = await File('/proc/stat').readAsString();
        } on FileSystemException {
          // Android may restrict the CPU counters to shell or system callers.
        }
      }

      if (output == null || !_cpuLine.hasMatch(output)) {
        final status = await getStatus();
        if (status['running'] != true || status['permission'] != true) {
          resetCpuBaseline();
          return {
            'available': false,
            'reason': '系統未開放讀取核心負載，需要 Shizuku 授權',
          };
        }
        output = await _api.runCommand('cat /proc/stat');
        source = 'Shizuku /proc/stat';
      }

      if (output == null || output.isEmpty) {
        return {
          'available': false,
          'reason': '無法讀取 /proc/stat',
        };
      }

      final samples = <int, double?>{};
      final hadBaseline = _cpuBaseline.containsKey(-1);
      for (final line in output.split('\n')) {
        final match = _cpuLine.firstMatch(line);
        if (match == null) continue;
        final core = int.tryParse(match[1]!) ?? -1;
        final values = line
            .substring(match.end)
            .trim()
            .split(RegExp(r'\s+'))
            .take(8)
            .map(int.tryParse)
            .whereType<int>()
            .toList();
        if (values.length != 8 || values.any((value) => value < 0)) continue;

        final total = values.reduce((sum, value) => sum + value);
        final idle = values[3] + values[4];
        final previous = _cpuBaseline[core];
        _cpuBaseline[core] = (total: total, idle: idle);
        samples[core] = null;
        if (previous == null) continue;
        final elapsed = total - previous.total;
        final idleElapsed = idle - previous.idle;
        if (elapsed > 0 && idleElapsed >= 0 && idleElapsed <= elapsed) {
          samples[core] = (elapsed - idleElapsed) * 100.0 / elapsed;
        }
      }
      _cpuBaseline.removeWhere((core, _) => !samples.containsKey(core));
      final usage = samples.remove(-1);

      return {
        'available': usage != null,
        'usage': usage,
        'coreUsage': samples,
        if (usage == null)
          'reason': hadBaseline ? 'CPU 取樣間隔無效' : '正在建立 CPU 取樣基準',
        'usageScope': 'Whole device',
        'source': source,
      };
    } catch (e) {
      return {
        'available': false,
        'reason': 'CPU 讀取失敗：$e',
      };
    }
  }

  /// 讀取 Android Thermal Zone 溫度
  Future<Map<String, dynamic>> getThermalSensors() async {
    try {
      final status = await getStatus();

      if (status['running'] != true ||
          status['permission'] != true) {
        return {
          'available': false,
          'sensors': <Map<String, dynamic>>[],
          'reason': '需要 Shizuku 授權',
        };
      }

      // 固定唯讀命令，不接受使用者輸入
      const command = r'''
          for d in /sys/class/thermal/thermal_zone*; do
            if [ -r "$d/type" ] && [ -r "$d/temp" ]; then
              t=$(cat "$d/type" 2>/dev/null)
              v=$(cat "$d/temp" 2>/dev/null)
              printf '%s|%s\n' "$t" "$v"
            fi
          done
          ''';

      final output = await _api.runCommand(command);

      if (output == null || output.trim().isEmpty) {
        return {
          'available': false,
          'sensors': <Map<String, dynamic>>[],
          'reason': '系統沒有開放溫度感測器',
        };
      }

      final sensors = <Map<String, dynamic>>[];

      for (final line in output.split('\n')) {
        final parts = line.trim().split('|');

        if (parts.length != 2) continue;

        final name = parts[0].trim();
        final raw = double.tryParse(parts[1].trim());

        if (name.isEmpty || raw == null) continue;

        // Linux thermal zone 通常使用毫攝氏度
        final temperature = raw.abs() >= 1000
            ? raw / 1000.0
            : raw;

        // 排除明顯無效的感測器數值
        if (temperature < -40 || temperature > 150) {
          continue;
        }

        sensors.add({
          'name': name,
          'temperatureC': temperature,
        });
      }

      return {
        'available': sensors.isNotEmpty,
        'sensors': sensors,
        'source': 'Shizuku Thermal Zone',
        'reason': sensors.isEmpty ? '沒有可用感測器' : null,
      };
    } catch (e) {
      return {
        'available': false,
        'sensors': <Map<String, dynamic>>[],
        'reason': '溫度讀取失敗：$e',
      };
    }
  }

  void resetCpuBaseline() {
    _cpuBaseline.clear();
  }
}
