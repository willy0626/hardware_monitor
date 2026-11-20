import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_monitor/cpu_details_page.dart';
import 'package:hardware_monitor/l10n/app_localizations.dart';
import 'package:hardware_monitor/services/shizuku_service.dart';
import 'package:shizuku_api_plugin/shizuku_api_platform_interface.dart';

class _CpuShizuku extends ShizukuApiPlatform {
  String counters = '';

  @override
  Future<bool?> pingBinder() async => true;

  @override
  Future<bool?> checkPermission() async => true;

  @override
  Future<String?> runCommand(String command) async => counters;
}

void main() {
  testWidgets('CPU details shows load and frequencies for eight cores', (
    tester,
  ) async {
    final samples = ValueNotifier<Map<String, dynamic>>({'usage': 18.0});
    final native = ValueNotifier<Map<String, dynamic>>({
      'cores': 8,
      'frequenciesByCoreMHz': {0: 1555, 2: 1017},
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: CpuDetailsPage(samples: samples, nativeCpu: native),
      ),
    );

    expect(find.text('CPU 7'), findsOneWidget);
    expect(find.text('1555 MHz'), findsOneWidget);
    expect(find.text('1017 MHz'), findsOneWidget);

    samples.value = {'usage': 23.0};
    await tester.pump();
    expect(find.text('CPU 負載 23.0%'), findsOneWidget);
    expect(find.byType(LineChart), findsOneWidget);
    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineBarsData.single.isCurved, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    samples.dispose();
    native.dispose();
  });

  test('aggregate and cores use their own sampling baselines', () async {
    final original = ShizukuApiPlatform.instance;
    final platform = _CpuShizuku();
    ShizukuApiPlatform.instance = platform;
    addTearDown(() => ShizukuApiPlatform.instance = original);
    final service = ShizukuService();

    platform.counters = '''
cpu 20 0 0 180 0 0 0 0
cpu0 10 0 0 90 0 0 0 0
cpu1 10 0 0 90 0 0 0 0
''';
    final first = await service.getSystemCpuUsage();
    expect(first['available'], isFalse);
    expect(first['coreUsage'], {0: null, 1: null});

    platform.counters = '''
cpu 40 0 0 260 0 0 0 0
cpu0 30 0 0 110 0 0 0 0
cpu1 10 0 0 150 0 0 0 0
''';
    final second = await service.getSystemCpuUsage();
    expect(second['usage'], 20);
    expect(second['coreUsage'], {0: 50, 1: 0});
  });
}
