import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';

class CpuDetailsPage extends StatefulWidget {
  const CpuDetailsPage({
    super.key,
    required this.samples,
    required this.nativeCpu,
    this.embedded = false,
  });

  final ValueListenable<Map<String, dynamic>> samples;
  final ValueListenable<Map<String, dynamic>> nativeCpu;
  final bool embedded;

  @override
  State<CpuDetailsPage> createState() => _CpuDetailsPageState();
}

class _CpuDetailsPageState extends State<CpuDetailsPage> {
  AppLocalizations get l10n => AppLocalizations.of(context)!;
  static const _historyLimit = 30;
  final _history = <double>[];
  final _knownCores = <int>{};
  final _loadChanges = ValueNotifier(0);
  final _coreChanges = ValueNotifier(0);
  Map<dynamic, dynamic> _frequencies = const {};
  int _coreCount = 0;

  num? get _systemLoad => widget.samples.value['usage'] as num?;
  num? get _load => _systemLoad ?? widget.nativeCpu.value['usage'] as num?;
  bool _wholeDevice = false;

  @override
  void initState() {
    super.initState();
    _onNativeSample();
    if (_systemLoad != null) _recordLoad();
    widget.samples.addListener(_onSystemSample);
    widget.nativeCpu.addListener(_onNativeSample);
  }

  void _recordLoad() {
    final coreUsage = widget.samples.value['coreUsage'] as Map<int, double?>?;
    if (coreUsage != null) _knownCores.addAll(coreUsage.keys);
    final wholeDevice = _systemLoad != null;
    if (wholeDevice != _wholeDevice) {
      _history.clear();
      _wholeDevice = wholeDevice;
    }
    final load = _load;
    if (load == null) return;
    _history.add(load.toDouble());
    if (_history.length > _historyLimit) _history.removeAt(0);
  }

  void _onSystemSample() {
    if (_systemLoad != null || _wholeDevice) {
      final knownCount = _knownCores.length;
      _recordLoad();
      _loadChanges.value++;
      if (knownCount != _knownCores.length) _coreChanges.value++;
    }
  }

  void _onNativeSample() {
    final cpu = widget.nativeCpu.value;
    final frequencies = cpu['frequenciesByCoreMHz'] as Map? ?? const {};
    final count = cpu['cores'] as int? ?? 0;
    if (count != _coreCount || !mapEquals(_frequencies, frequencies)) {
      _coreCount = count;
      _frequencies = frequencies;
      _coreChanges.value++;
    }
    if (_systemLoad == null) {
      _recordLoad();
      _loadChanges.value++;
    }
  }

  @override
  void dispose() {
    widget.samples.removeListener(_onSystemSample);
    widget.nativeCpu.removeListener(_onNativeSample);
    _loadChanges.dispose();
    _coreChanges.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final size = MediaQuery.sizeOf(context);
    final compact = widget.embedded && size.width >= 600 &&
        size.width > size.height && size.height < 600;
    final card = Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: compact ? 90 : 150,
            child: RepaintBoundary(
              child: ListenableBuilder(
                listenable: _loadChanges,
                builder: (_, _) => _history.length < 2
                    ? const SizedBox.shrink()
                    : ExcludeSemantics(child: _buildChart(accent)),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(compact ? 10 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListenableBuilder(
                  listenable: _loadChanges,
                  builder: (_, _) {
                    final load = _load;
                    return Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          l10n.cpuLoad(
                            load == null ? '—' : '${load.toStringAsFixed(1)}%',
                          ),
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: accent,
                          ),
                        ),
                        if (load != null)
                          Text(_wholeDevice ? l10n.wholeDevice : l10n.appOnly),
                      ],
                    );
                  },
                ),
                SizedBox(height: compact ? 6 : 12),
                ListenableBuilder(
                  listenable: _coreChanges,
                  builder: (_, _) {
                    final cores = {
                      for (var core = 0; core < _coreCount; core++) core,
                      ..._knownCores,
                      ..._frequencies.keys.whereType<int>(),
                    }.toList()..sort();
                    if (cores.isEmpty) {
                      return Text(l10n.clocksUnavailable);
                    }
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 8,
                              mainAxisSpacing: compact ? 4 : 8,
                              mainAxisExtent: compact ? 44 : 64,
                          ),
                      itemCount: cores.length,
                      itemBuilder: (context, index) {
                        final core = cores[index];
                        final mhz = _frequencies[core];
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface.withValues(
                              alpha: 0.75,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'CPU $core',
                                style: theme.textTheme.labelMedium,
                              ),
                              Text(
                                mhz is num ? '$mhz MHz' : '—',
                                style: theme.textTheme.titleMedium,
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (widget.embedded) return card;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.cpuUsage)),
      body: ListView(padding: const EdgeInsets.all(12), children: [card]),
    );
  }

  Widget _buildChart(Color color) {
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: _historyLimit - 1.0,
        minY: 0,
        maxY: 100,
        clipData: const FlClipData.all(),
        titlesData: const FlTitlesData(show: false),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var index = 0; index < _history.length; index++)
                FlSpot(
                  (_historyLimit - _history.length + index).toDouble(),
                  _history[index],
                ),
            ],
            color: color.withValues(alpha: 0.65),
            barWidth: 2,
            isCurved: true,
            preventCurveOverShooting: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.22),
            ),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }
}
