
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class HardwareChannel {
  static const MethodChannel _channel =
      MethodChannel('hardware_monitor/native');
  static const _batteryChannel = EventChannel('hardware_monitor/battery');

  Stream<Map<String, dynamic>> get batteryUpdates => _batteryChannel
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  Future<Map<String, dynamic>> getBatteryDetails() async {
    return await _channel.invokeMapMethod<String, dynamic>('getBatteryDetails') ??
        {};
  }

  Future<int?> getBatteryVoltage() =>
      _channel.invokeMethod<int>('getBatteryVoltage');

  Future<Map<String, dynamic>> getCpuInfo() async =>
      await _channel.invokeMapMethod<String, dynamic>('getCpuInfo') ?? {};

  Future<Map<String, dynamic>> getHardwareInfo({bool includeCpu = true}) async {
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>(
        'getHardwareInfo',
        {'includeCpu': includeCpu},
      );

      return result ?? {};
    } on PlatformException catch (e) {
      debugPrint('原生平台錯誤：${e.code}');
      debugPrint('錯誤訊息：${e.message}');
      debugPrint('錯誤詳細資料：${e.details}');

      return {
        'error': '${e.code}: ${e.message}',
      };
    } on MissingPluginException catch (e) {
      debugPrint('找不到原生 MethodChannel：$e');

      return {
        'error': 'MissingPluginException: $e',
      };
    } catch (e, stackTrace) {
      debugPrint('硬體監控未知錯誤：$e');
      debugPrint('$stackTrace');

      return {
        'error': e.toString(),
      };
    }
  }
}
