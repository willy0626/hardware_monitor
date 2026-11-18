import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/platform/hardware_channel.dart';
import 'shizuku_service.dart';

enum BatteryDetail {
  technology('電池技術'),
  voltage('電壓'),
  manufactureDate('製造日期'),
  firstUseDate('初次使用'),
  designCapacity('典型容量'),
  ratedCapacity('額定容量'),
  health('電池健康度'),
  cycles('充電循環');

  const BatteryDetail(this.label);
  final String label;
}

class BatteryDetailsService {
  BatteryDetailsService(this._hardware, this._shizuku);

  final HardwareChannel _hardware;
  final ShizukuService _shizuku;

  Future<String?> loadVoltage() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return _format(
        BatteryDetail.voltage,
        await _hardware.getBatteryVoltage(),
        1000,
      );
    } catch (error) {
      debugPrint('Battery voltage: $error');
      return null;
    }
  }

  // Linux power_supply reports voltage in µV and charge in µAh.
  static const _attributes = {
    'technology': BatteryDetail.technology,
    'voltage_now': BatteryDetail.voltage,
    'manufacturing_date': BatteryDetail.manufactureDate,
    'first_usage_date': BatteryDetail.firstUseDate,
    'charge_full_rated': BatteryDetail.ratedCapacity,
    'state_of_health': BatteryDetail.health,
    'health_index': BatteryDetail.health,
    'cycle_count': BatteryDetail.cycles,
  };

  Future<Map<BatteryDetail, String>> load() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return {};

    var native = <String, dynamic>{};
    try {
      native = await _hardware.getBatteryDetails();
    } catch (error) {
      debugPrint('Battery details channel: $error');
    }

    final samsung =
        native['manufacturer']?.toString().toLowerCase() == 'samsung';
    final details = <BatteryDetail, String>{};
    String? zeroCycles;
    void add(BatteryDetail field, Object? raw, {double divisor = 1}) {
      if (details.containsKey(field)) return;
      final value = _format(field, raw, divisor);
      if (samsung && field == BatteryDetail.cycles && _number(raw) == 0) {
        // Some Samsung devices report zero through Android while retaining
        // the actual count in their vendor battery data.
        zeroCycles = value;
        return;
      }
      if (value != null) details[field] = value;
    }

    add(BatteryDetail.technology, native['technology']);
    add(BatteryDetail.voltage, native['voltageMv'], divisor: 1000);
    add(BatteryDetail.manufactureDate, native['manufactureDate']);
    add(BatteryDetail.firstUseDate, native['firstUseDate']);
    add(BatteryDetail.health, native['healthPercent']);
    add(BatteryDetail.cycles, native['cycleCount']);

    void addProfileCapacities(Object? typical, Object? capacity) {
      add(BatteryDetail.designCapacity, typical);
      final typicalMah =
          _number(typical) ?? _number(native['typicalCapacityMah']);
      final capacityMah = _number(capacity);
      // Samsung profiles can expose separate typical and rated values.
      if (samsung &&
          typicalMah != null &&
          capacityMah != null &&
          capacityMah != 1000 &&
          capacityMah <= typicalMah) {
        add(BatteryDetail.ratedCapacity, capacityMah);
      }
    }

    final attributes = {
      ..._attributes,
      if (samsung) 'batt_asoc': BatteryDetail.health,
    };
    for (final supply in ['battery', 'bms']) {
      for (final entry in attributes.entries) {
        if (details.containsKey(entry.value)) continue;
        try {
          final raw = await File('/sys/class/power_supply/$supply/${entry.key}')
              .readAsString();
          add(entry.value, raw, divisor: _sysfsDivisor(entry.value));
        } on FileSystemException {
          // Missing or protected attributes can be retried through Shizuku.
        }
      }
    }
    addProfileCapacities(
      native['typicalCapacityMah'],
      native['profileCapacityMah'],
    );

    if (details.length == BatteryDetail.values.length) return details;
    final missingAttributes = attributes.entries
        .where((entry) => !details.containsKey(entry.value))
        .map((entry) => entry.key)
        .join(' ');
    // Only fixed attribute names are interpolated into this read-only command.
    final needsProfile =
        samsung &&
        (!details.containsKey(BatteryDetail.designCapacity) ||
            !details.containsKey(BatteryDetail.ratedCapacity));
    final needsManufactureDate = !details.containsKey(
      BatteryDetail.manufactureDate,
    );
    final command =
        'for supply in battery bms; do\n'
        '  for key in $missingAttributes; do\n'
        r'    value=$(cat "/sys/class/power_supply/$supply/$key" 2>/dev/null) || continue'
        '\n'
        r'''    printf 'sysfs.%s: %s\n' "$key" "$value"'''
        '\n  done\ndone\n'
        '${needsManufactureDate ? _manufactureDateCommand : ''}'
        'dumpsys battery 2>/dev/null'
        '${needsProfile ? '\ndumpsys batterystats --power-profile 2>/dev/null' : ''}';
    try {
      final output = await _shizuku.readBatteryDetails(command);
      if (needsProfile && output != null) {
        final profile = {
          for (final match in RegExp(
            r'^\s*(battery\.(?:typical\.)?capacity)\s*[:=]\s*(\d+(?:\.\d+)?)\s*$',
            multiLine: true,
          ).allMatches(output))
            match[1]!: match[2],
        };
        addProfileCapacities(
          profile['battery.typical.capacity'],
          native['profileCapacityMah'] ?? profile['battery.capacity'],
        );
      }
      final dump = <String, String>{};
      for (final line in (output ?? '').split('\n')) {
        final separator = line.indexOf(':');
        if (separator < 0) continue;
        final key = line.substring(0, separator).trim().toLowerCase();
        final value = line.substring(separator + 1).trim();
        if (key.startsWith('sysfs.')) {
          final field = attributes[key.substring(6)];
          if (field != null) add(field, value, divisor: _sysfsDivisor(field));
        } else {
          dump[key] = value;
        }
      }
      add(BatteryDetail.technology, dump['technology']);
      add(BatteryDetail.voltage, dump['voltage'], divisor: 1000);
      add(BatteryDetail.manufactureDate, dump['manufacturing date']);
      add(
        BatteryDetail.manufactureDate,
        dump['batterymanufacturingdateseconds'],
      );
      add(BatteryDetail.firstUseDate, dump['first usage date']);
      add(BatteryDetail.health, dump['state of health']);
      add(BatteryDetail.cycles, dump['cycle count']);
      add(BatteryDetail.cycles, dump['cycle_count']);
      if (samsung) {
        add(BatteryDetail.manufactureDate, dump['battery manufacturingdate']);
        add(BatteryDetail.manufactureDate, dump['battery manufacturedate']);
        add(BatteryDetail.manufactureDate, dump['llb man']);
        add(BatteryDetail.firstUseDate, dump['battery firstusedate']);
        add(BatteryDetail.health, dump['msavedbatterybsoh']);
        add(BatteryDetail.health, dump['msavedbatteryasoc']);
        add(BatteryDetail.cycles, dump['battery cyclecount']);
        final usage = _number(dump['msavedbatteryusage']);
        if (usage != null &&
            usage >= 0 &&
            (usage >= 100 || zeroCycles == null)) {
          details.putIfAbsent(
            BatteryDetail.cycles,
            () => '約 ${(usage / 100).floor()} 次',
          );
        }
      }
    } catch (error) {
      debugPrint('Shizuku battery details: $error');
    }
    if (needsManufactureDate &&
        !details.containsKey(BatteryDetail.manufactureDate) &&
        (native['sdkInt'] as int? ?? 0) >= 34) {
      try {
        // IBatteryPropertiesRegistrar.getProperty(7), using Shizuku's shell identity.
        final reply = await _shizuku.readBatteryDetails(
          'service call batteryproperties 1 i32 7',
        );
        add(BatteryDetail.manufactureDate, _readManufactureDateReply(reply));
      } catch (error) {
        debugPrint('Shizuku battery manufacturing date: $error');
      }
    }
    if (zeroCycles != null) {
      details.putIfAbsent(BatteryDetail.cycles, () => zeroCycles!);
    }
    return details;
  }

  static int? _readManufactureDateReply(String? reply) {
    if (reply == null) return null;
    // The successful reply contains no exception, status 0, a present
    // BatteryProperty, then its 64-bit value (low word first).
    final match = RegExp(
      r'^\s*Result: Parcel\(\s*(?:0x00000000:\s*)?'
      r'00000000\s+00000000\s+00000001\s+([0-9a-f]{8})'
      r"(?:\s+'[^\r\n]*'\s+0x00000010:\s*|\s+)"
      r'00000000(?=\s|\))',
      caseSensitive: false,
    ).firstMatch(reply);
    return match == null ? null : int.parse(match[1]!, radix: 16);
  }

  // Some devices expose the Health HAL attribute under another battery supply.
  static const _manufactureDateCommand = r'''
for supply in /sys/class/power_supply/*; do
  case "${supply##*/}" in battery|bms) continue ;; esac
  [ "$(cat "$supply/type" 2>/dev/null)" = Battery ] || continue
  value=$(cat "$supply/manufacturing_date" 2>/dev/null) || continue
  printf 'sysfs.manufacturing_date: %s\n' "$value"
done
''';

  static double _sysfsDivisor(BatteryDetail field) => switch (field) {
    BatteryDetail.voltage => 1000000,
    BatteryDetail.designCapacity || BatteryDetail.ratedCapacity => 1000,
    _ => 1,
  };

  static String _clean(Object? raw) =>
      (raw?.toString() ?? '').trim().replaceAll(RegExp(r'^\[|\]$'), '').trim();

  static double? _number(Object? raw) {
    final value = double.tryParse(_clean(raw));
    return value != null && value.isFinite ? value : null;
  }

  static String? _format(BatteryDetail field, Object? raw, double divisor) {
    switch (field) {
      case BatteryDetail.technology:
        final text = _clean(raw);
        return text.isEmpty || text.toLowerCase() == 'unknown' ? null : text;
      case BatteryDetail.manufactureDate:
      case BatteryDetail.firstUseDate:
        return _formatDate(_clean(raw));
      default:
        break;
    }

    final number = _number(raw);
    if (number == null) return null;
    final value = number / divisor;
    return switch (field) {
      BatteryDetail.voltage when value > 0 => '${value.toStringAsFixed(2)} V',
      BatteryDetail.designCapacity ||
      BatteryDetail.ratedCapacity when value > 0 => '${value.round()} mAh',
      BatteryDetail.health when value > 0 && value <= 100 =>
        '${value == value.round() ? value.round() : value}%',
      BatteryDetail.cycles when value >= 0 && value == value.round() =>
        '${value.round()} 次',
      _ => null,
    };
  }

  static String? _formatDate(String raw) {
    final calendar = RegExp(r'^(\d{4})([-/.]?)(\d{2})\2(\d{2})$')
        .firstMatch(raw);
    DateTime date;
    if (calendar != null) {
      final year = int.parse(calendar[1]!);
      final month = int.parse(calendar[3]!);
      final day = int.parse(calendar[4]!);
      date = DateTime.utc(year, month, day);
      if (date.year != year || date.month != month || date.day != day) {
        return null;
      }
    } else {
      final seconds = int.tryParse(raw);
      if (seconds == null || seconds <= 0 || seconds >= 4102444800) return null;
      date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    }
    if (date.year < 2000 || date.year >= 2100) return null;
    return date.toIso8601String().substring(0, 10);
  }
}
