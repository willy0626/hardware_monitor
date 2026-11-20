import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_monitor/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('five languages fit a narrow screen and switch in settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(
      () => SharedPreferencesAsyncPlatform.instance = originalPreferences,
    );

    final messenger = tester.binding.defaultBinaryMessenger;
    const battery = MethodChannel('hardware_monitor/battery');
    messenger.setMockMethodCallHandler(battery, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(battery, null));

    await tester.pumpWidget(const HardwareMonitorApp(initialLanguage: 'zh'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('設定'));
    await tester.pumpAndSettle();

    var languageLabel = '語言';
    var settingsLabel = '設定';
    const choices = [
      ('简体中文', '语言', '设置', '性能'),
      ('English', 'Language', 'Settings', 'Performance'),
      ('日本語', '言語', '設定', 'パフォーマンス'),
      ('한국어', '언어', '설정', '성능'),
      ('繁體中文', '語言', '設定', '效能'),
    ];
    for (final (name, nextLanguage, nextSettings, monitor) in choices) {
      await tester.tap(find.text(languageLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
      expect(find.text(nextLanguage), findsOneWidget);
      expect(find.text(nextSettings), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text(monitor));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip(nextSettings));
      await tester.pumpAndSettle();
      languageLabel = nextLanguage;
      settingsLabel = nextSettings;
    }
    expect(find.text(settingsLabel), findsOneWidget);
    expect(await SharedPreferencesAsync().getString('language'), 'zh');
    tester.binding.platformDispatcher.localesTestValue = const [Locale('ja')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    await tester.tap(find.text(languageLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隨系統').last);
    await tester.pumpAndSettle();
    expect(find.text('言語'), findsOneWidget);
    expect(await SharedPreferencesAsync().getString('language'), '');
    tester.binding.platformDispatcher.localesTestValue = const [
      Locale('zh', 'CN'),
    ];
    await tester.pumpAndSettle();
    expect(find.text('语言'), findsOneWidget);
    tester.view.physicalSize = const Size(760, 420);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byTooltip('电池'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final information = tester.getTopLeft(find.text('信息'));
    final capacity = tester.getTopLeft(find.text('容量与健康'));
    expect(information.dx, lessThan(capacity.dx));
    expect(information.dy, closeTo(capacity.dy, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
