import 'dart:async';

import 'package:flutter/material.dart';

import 'services/battery_details_service.dart';

class BatteryDetailsPage extends StatefulWidget {
  const BatteryDetailsPage({super.key, required this.service});

  final BatteryDetailsService service;

  @override
  State<BatteryDetailsPage> createState() => _BatteryDetailsPageState();
}

class _BatteryDetailsPageState extends State<BatteryDetailsPage> {
  late Future<Map<BatteryDetail, String>> _details;
  late final AppLifecycleListener _lifecycle;
  Timer? _voltageTimer;
  bool _readingVoltage = false;
  String? _voltage;

  @override
  void initState() {
    super.initState();
    _details = widget.service.load();
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
    return Scaffold(
      appBar: AppBar(title: const Text('電池詳細資訊')),
      body: FutureBuilder<Map<BatteryDetail, String>>(
        future: _details,
        builder: (context, snapshot) {
          final loading = snapshot.connectionState == ConnectionState.waiting;
          final details = {
            ...?snapshot.data,
            if (_voltage != null) BatteryDetail.voltage: _voltage!,
          };
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _details = widget.service.load());
              await _details;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              children: [
                if (loading)
                  const LinearProgressIndicator(semanticsLabel: '讀取電池詳細資訊'),
                _buildCard(
                  '資訊',
                  BatteryDetail.values.take(4),
                  details,
                  loading,
                ),
                const SizedBox(height: 10),
                _buildCard(
                  '容量與健康',
                  BatteryDetail.values.skip(4),
                  details,
                  loading,
                ),
                if (!loading && details.length < BatteryDetail.values.length)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: Text('部分資料無法讀取。啟動並授權 Shizuku 後，可下拉重新讀取。'),
                  ),
              ],
            ),
          );
        },
      ),
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
              title: Text(field.label),
              trailing: Text(details[field] ?? (loading ? '…' : '無法取得')),
            ),
        ],
      ),
    );
  }
}
