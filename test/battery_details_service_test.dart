import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_monitor/core/platform/hardware_channel.dart';
import 'package:hardware_monitor/services/battery_details_service.dart';
import 'package:hardware_monitor/services/shizuku_service.dart';

String _localDate(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000)
        .toIso8601String()
        .substring(0, 10);

class _BatteryHardware extends HardwareChannel {
  _BatteryHardware({
    this.typicalCapacityMah,
    this.manufactureDate = 1735689600,
    this.cycleCount = -1,
  });

  final int? typicalCapacityMah;
  final int? manufactureDate;
  final int cycleCount;

  @override
  Future<Map<String, dynamic>> getBatteryDetails() async => {
    'manufacturer': 'Samsung',
    'sdkInt': 36,
    'voltageMv': 3920,
    'manufactureDate': manufactureDate,
    'profileCapacityMah': 4855,
    'typicalCapacityMah': typicalCapacityMah,
    'healthPercent': -1,
    'cycleCount': cycleCount,
  };
}

class _BatteryShizuku extends ShizukuService {
  _BatteryShizuku(this.output, {this.manufactureReply});

  final String? output;
  final String? manufactureReply;

  @override
  Future<String?> readBatteryDetails(String command) async =>
      command == 'service call batteryproperties 1 i32 7'
      ? manufactureReply
      : output;
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Samsung usage can supply a count when Android reports zero', () async {
    final service = BatteryDetailsService(
      _BatteryHardware(cycleCount: 0),
      _BatteryShizuku('cycle count: 0\nmSavedBatteryUsage: [36245]'),
    );

    final details = await service.load();
    expect(details[BatteryDetail.cycles], '約 362 次');
  });

  test('Android zero is kept when Samsung has no higher cycle count', () async {
    final service = BatteryDetailsService(
      _BatteryHardware(cycleCount: 0),
      _BatteryShizuku('mSavedBatteryUsage: [45]'),
    );

    final details = await service.load();
    expect(details[BatteryDetail.cycles], '0 次');
  });

  test(
    'Shizuku fills missing fields without replacing system values',
    () async {
      final service = BatteryDetailsService(
        _BatteryHardware(),
        _BatteryShizuku('''
battery.typical.capacity = 5000.0
technology: Li-ion
voltage: 4000
battery FirstUseDate: [20250203]
mSavedBatteryBsoh: 97.5
mSavedBatteryUsage: [3482]
'''),
      );

      expect(await service.load(), {
        BatteryDetail.technology: 'Li-ion',
        BatteryDetail.voltage: '3.92 V',
        BatteryDetail.manufactureDate: _localDate(1735689600),
        BatteryDetail.firstUseDate: '2025-02-03',
        BatteryDetail.designCapacity: '5000 mAh',
        BatteryDetail.ratedCapacity: '4855 mAh',
        BatteryDetail.health: '97.5%',
        BatteryDetail.cycles: '約 34 次',
      });
    },
  );

  test('protected fields stay absent without Shizuku output', () async {
    final service = BatteryDetailsService(
      _BatteryHardware(),
      _BatteryShizuku(null),
    );

    expect(await service.load(), {
      BatteryDetail.voltage: '3.92 V',
      BatteryDetail.manufactureDate: _localDate(1735689600),
    });
  });

  test('Samsung power profile classifies typical and rated capacity', () async {
    final service = BatteryDetailsService(
      _BatteryHardware(typicalCapacityMah: 5000),
      _BatteryShizuku(null),
    );

    final details = await service.load();
    expect(details[BatteryDetail.designCapacity], '5000 mAh');
    expect(details[BatteryDetail.ratedCapacity], '4855 mAh');
  });

  test('Samsung assembly date is read independently of first use', () async {
    final service = BatteryDetailsService(
      _BatteryHardware(manufactureDate: null),
      _BatteryShizuku('''
battery ManufactureDate: [2024/02/30]
LLB MAN: 2025/01/15
battery FirstUseDate: [20250203]
'''),
    );

    final details = await service.load();
    expect(details[BatteryDetail.manufactureDate], '2025-01-15');
    expect(details[BatteryDetail.firstUseDate], '2025-02-03');
  });

  test(
    'Shizuku reads the manufacturing property when the dump has no date',
    () async {
      final service = BatteryDetailsService(
        _BatteryHardware(manufactureDate: null),
        _BatteryShizuku(
          'battery FirstUseDate: [20250203]',
          manufactureReply: '''
Result: Parcel(
  0x00000000: 00000000 00000000 00000001 67756680 '................'
  0x00000010: 00000000                            '....')
''',
        ),
      );

      final details = await service.load();
      expect(details[BatteryDetail.manufactureDate], _localDate(1735747200));
      expect(details[BatteryDetail.firstUseDate], '2025-02-03');
    },
  );
}
