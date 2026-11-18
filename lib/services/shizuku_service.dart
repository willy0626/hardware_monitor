
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

  int? _lastTotal;
  int? _lastIdle;

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
      final status = await getStatus();

      if (status['running'] != true ||
          status['permission'] != true) {
        return {
          'available': false,
          'reason': 'Shizuku 尚未授權',
        };
      }

      final output = await _api.runCommand('cat /proc/stat');

      if (output == null || output.isEmpty) {
        return {
          'available': false,
          'reason': '無法讀取 /proc/stat',
        };
      }

      final line = output
          .split('\n')
          .firstWhere(
            (line) => line.startsWith('cpu '),
            orElse: () => '',
          );

      if (line.isEmpty) {
        return {
          'available': false,
          'reason': 'CPU 資料格式不正確',
        };
      }

      final values = line
          .trim()
          .split(RegExp(r'\s+'))
          .skip(1)
          .map((value) => int.tryParse(value) ?? 0)
          .toList();

      if (values.length < 8) {
        return {
          'available': false,
          'reason': 'CPU 資料不足',
        };
      }

      // Linux /proc/stat 前八個欄位
      final total = values.take(8).fold<int>(
        0,
        (sum, value) => sum + value,
      );

      final idle = values[3] + values[4];

      if (_lastTotal == null || _lastIdle == null) {
        _lastTotal = total;
        _lastIdle = idle;

        return {
          'available': false,
          'reason': '正在建立 CPU 取樣基準',
        };
      }

      final totalDiff = total - _lastTotal!;
      final idleDiff = idle - _lastIdle!;

      _lastTotal = total;
      _lastIdle = idle;

      if (totalDiff <= 0) {
        return {
          'available': false,
          'reason': 'CPU 取樣間隔無效',
        };
      }

      final usage =
          (1.0 - idleDiff / totalDiff) * 100.0;

      return {
        'available': true,
        'usage': usage.clamp(0.0, 100.0),
        'usageScope': 'Whole device',
        'source': 'Shizuku /proc/stat',
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
      debugPrint('Thermal Zone Output: $output');

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
    _lastTotal = null;
    _lastIdle = null;
  }
}
