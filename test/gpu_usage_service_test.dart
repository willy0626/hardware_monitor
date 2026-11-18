import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_monitor/services/gpu_usage_service.dart';
import 'package:hardware_monitor/services/shizuku_service.dart';

class _GpuShizuku extends ShizukuService {
  _GpuShizuku(this.output);

  final String output;

  @override
  Future<String?> readSystemData(String command) async => output;
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('uses the kernel percentage including a valid zero', () async {
    final service = GpuUsageService(_GpuShizuku('percentage:0 %\nbusy:25 100'));
    expect(await service.load(), 0);
  });

  test(
    'calculates the busy ratio when the percentage is unavailable',
    () async {
      final service = GpuUsageService(
        _GpuShizuku('percentage:\nbusy:250 1000'),
      );
      expect(await service.load(), 25);
    },
  );

  test('unavailable counters do not look like an idle GPU', () async {
    final service = GpuUsageService(_GpuShizuku('percentage:\nbusy:0 0'));
    expect(await service.load(), isNull);
  });
}
