import 'dart:io';

import 'package:flutter/foundation.dart';

import 'shizuku_service.dart';

class GpuUsageService {
  GpuUsageService(this._shizuku);

  final ShizukuService _shizuku;

  // Qualcomm KGSL exposes a percentage and an interval's busy/total times.
  static const _kgsl = '/sys/class/kgsl/kgsl-3d0';
  static const _percentagePath = '$_kgsl/gpu_busy_percentage';
  static const _busyPath = '$_kgsl/gpubusy';

  Future<double?> load() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;

    final system =
        _percentage(await _read(_percentagePath)) ??
        _busyRatio(await _read(_busyPath));
    if (system != null) return system;

    try {
      final output = await _shizuku.readSystemData(
        'printf "percentage:"; cat $_percentagePath 2>/dev/null; '
        'printf "\\nbusy:"; cat $_busyPath 2>/dev/null',
      );
      if (output == null) return null;
      final readings = <String, String>{};
      for (final line in output.split('\n')) {
        final delimiter = line.indexOf(':');
        if (delimiter < 0) continue;
        readings[line.substring(0, delimiter)] = line.substring(delimiter + 1);
      }
      return _percentage(readings['percentage']) ??
          _busyRatio(readings['busy']);
    } catch (error) {
      debugPrint('Shizuku GPU usage: $error');
      return null;
    }
  }

  Future<String?> _read(String path) async {
    try {
      return await File(path).readAsString();
    } on FileSystemException {
      return null;
    }
  }

  double? _percentage(String? raw) {
    final text = (raw ?? '').trim().replaceFirst(RegExp(r'%$'), '').trim();
    final value = double.tryParse(text);
    return value != null && value >= 0 && value <= 100 ? value : null;
  }

  double? _busyRatio(String? raw) {
    final fields = (raw ?? '').trim().split(RegExp(r'\s+'));
    if (fields.length != 2) return null;
    final busy = int.tryParse(fields[0]);
    final total = int.tryParse(fields[1]);
    if (busy == null ||
        total == null ||
        total <= 0 ||
        busy < 0 ||
        busy > total) {
      return null;
    }
    return 100.0 * busy / total;
  }
}
