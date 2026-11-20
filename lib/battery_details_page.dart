import 'dart:async';

import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';

import 'services/battery_details_service.dart';

class BatteryDetailsPage extends StatefulWidget {
  const BatteryDetailsPage({
    super.key,
    required this.service,
    this.summary,
    this.compact = false,
  });

  final BatteryDetailsService service;
  final Widget? summary;
  final bool compact;

  @override
  State<BatteryDetailsPage> createState() => _BatteryDetailsPageState();
}

class _BatteryDetailsPageState extends State<BatteryDetailsPage> {
  AppLocalizations get l10n => AppLocalizations.of(context)!;
  late Future<Map<BatteryDetail, String>> _details;
  String? _detailsLocale;
  late final AppLifecycleListener _lifecycle;
  Timer? _voltageTimer;
  bool _readingVoltage = false;
  String? _voltage;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed) {
          _startVoltageUpdates();
        } else {
          _stopVoltageUpdates();
        }
      },
    );
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _startVoltageUpdates();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_detailsLocale != l10n.localeName) {
      _detailsLocale = l10n.localeName;
      _details = _loadDetails();
    }
  }

  Future<Map<BatteryDetail, String>> _loadDetails() {
    final strings = l10n;
    return widget.service.load(
      formatCycles: (count, estimated) => estimated
          ? strings.estimatedCycleValue(count)
          : strings.cycleValue(count),
    );
  }

  void _startVoltageUpdates() {
    _voltageTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateVoltage(),
    );
  }

  void _stopVoltageUpdates() {
    _voltageTimer?.cancel();
    _voltageTimer = null;
  }

  Future<void> _updateVoltage() async {
    if (_readingVoltage || ModalRoute.of(context)?.isCurrent == false) return;
    _readingVoltage = true;
    try {
      final voltage = await widget.service.loadVoltage();
      if (mounted &&
          _voltageTimer != null &&
          voltage != null &&
          voltage != _voltage) {
        setState(() => _voltage = voltage);
      }
    } finally {
      _readingVoltage = false;
    }
  }

  @override
  void dispose() {
    _stopVoltageUpdates();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = FutureBuilder<Map<BatteryDetail, String>>(
      future: _details,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState == ConnectionState.waiting;
        final details = {...?snapshot.data, BatteryDetail.voltage: ?_voltage};
        final information = _buildCard(
          l10n.information,
          BatteryDetail.values.take(4),
          details,
          loading,
        );
        final capacity = _buildCard(
          l10n.capacityHealth,
          BatteryDetail.values.skip(4),
          details,
          loading,
        );
        return RefreshIndicator(
          onRefresh: () async {
            setState(() => _details = _loadDetails());
            await _details;
          },
          child: ListView(
            key: const PageStorageKey('battery'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.all(widget.compact ? 8 : 12),
            children: [
              ?widget.summary,
              if (loading)
                LinearProgressIndicator(semanticsLabel: l10n.loadingBattery),
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < (widget.compact ? 500 : 580)) {
                    return Column(children: [information, capacity]);
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: information),
                      const SizedBox(width: 8),
                      Expanded(child: capacity),
                    ],
                  );
                },
              ),
              if (!loading && details.length < BatteryDetail.values.length)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: Text(l10n.batteryPartial),
                ),
            ],
          ),
        );
      },
    );
    if (widget.summary != null) return content;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.batteryDetails)),
      body: content,
    );
  }

  Widget _buildCard(
    String title,
    Iterable<BatteryDetail> fields,
    Map<BatteryDetail, String> details,
    bool loading,
  ) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final field in fields)
            ListTile(
              dense: true,
              title: Text(switch (field) {
                BatteryDetail.technology => l10n.batteryTechnology,
                BatteryDetail.voltage => l10n.voltage,
                BatteryDetail.manufactureDate => l10n.manufactureDate,
                BatteryDetail.firstUseDate => l10n.firstUse,
                BatteryDetail.designCapacity => l10n.typicalCapacity,
                BatteryDetail.ratedCapacity => l10n.ratedCapacity,
                BatteryDetail.health => l10n.batteryHealth,
                BatteryDetail.cycles => l10n.chargeCycles,
              }),
              trailing: Text(
                details[field] ?? (loading ? '…' : l10n.unavailable),
              ),
            ),
        ],
      ),
    );
  }
}
