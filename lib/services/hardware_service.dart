
import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';

class HardwareService {
  final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();
  final Battery _battery = Battery();

  /// 取得裝置硬體與系統資訊
  Future<Map<String, String>> getDeviceInfo() async {
    Map<String, String> deviceData = {};

    try {
      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo =
            await _deviceInfoPlugin.androidInfo;

        deviceData = {
          'brand': androidInfo.brand,
          'manufacturer': androidInfo.manufacturer,
          'model': androidInfo.model,
          'deviceName':
              '${androidInfo.manufacturer} ${androidInfo.model}',
          'osVersion':
              'Android ${androidInfo.version.release} (SDK ${androidInfo.version.sdkInt})',
          'hardware': androidInfo.hardware,
          'board': androidInfo.board,
          'device': androidInfo.device,
          'product': androidInfo.product,
          'securityPatch': androidInfo.version.securityPatch ?? '',
          'buildId': androidInfo.id,
          'buildDisplay': androidInfo.display,
          'bootloader': androidInfo.bootloader,
          'abis': androidInfo.supportedAbis.join(', '),
        };
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo =
            await _deviceInfoPlugin.iosInfo;

        deviceData = {
          'brand': 'Apple',
          'model': iosInfo.utsname.machine,
          'deviceName': iosInfo.name,
          'osVersion':
              '${iosInfo.systemName} ${iosInfo.systemVersion}',
          'hardware': iosInfo.utsname.machine,
          'board': 'N/A',
          'device': iosInfo.model,
        };
      }
    } catch (e) {
      deviceData = {
        'error': '無法取得裝置資訊: $e'
      };
    }

    return deviceData;
  }

  /// 取得當前電池電量百分比 (0 - 100)
  Future<int> getBatteryLevel() async {
    try {
      return await _battery.batteryLevel;
    } catch (e) {
      return -1;
    }
  }

  /// 監聽電池充電狀態即時變化
  Stream<BatteryState> get batteryStateStream =>
      _battery.onBatteryStateChanged;
}
