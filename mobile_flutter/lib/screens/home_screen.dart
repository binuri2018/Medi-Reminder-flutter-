import "package:flutter/material.dart";
import "dart:async";
import "package:flutter/foundation.dart";
import "package:permission_handler/permission_handler.dart";
import "package:flutter_tts/flutter_tts.dart";
import "package:vibration/vibration.dart";

import "../models/reminder_model.dart";
import "../services/api_service.dart";
import "../services/bluetooth_mode_service.dart";
import "../services/outdoor_alarm_service.dart";
import "../widgets/mode_badge.dart";
import "../widgets/reminder_card.dart";

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final ApiService _api = ApiService();
  final BluetoothModeService _bluetooth = BluetoothModeService();
  final FlutterTts _tts = FlutterTts();
  String _mode = "indoor";
  String _modeSource = "manual";
  String _autoModeSetting = "manual";
  String _bluetoothStatus = "idle";
  String _bluetoothReason = "";
  int? _lastRssi;
  ReminderModel? _latest;
  List<ReminderModel> _history = [];
  bool _loading = true;
  String _error = "";
  // Strict centralized polling: one owner, one core timer, one history timer.
  static const Duration _kModePollInterval = Duration(seconds: 5);
  static const Duration _kHistoryPollInterval = Duration(seconds: 30);
  static const Duration _kBluetoothTickInterval = Duration(seconds: 15);

  Timer? _corePollTimer;
  Timer? _historyPollTimer;
  Timer? _bluetoothPollTimer;
  bool _coreRefreshInFlight = false;
  bool _historyRefreshInFlight = false;
  bool _bluetoothTickInFlight = false;
  bool _bluetoothPermissionGranted = false;
  DateTime? _lastCoreRefresh;
  DateTime? _lastHistoryRefresh;
  String? _lastAlertKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestNotificationPermission();
    _setupTts();
    _initBluetooth();
    _startPolling();
  }

  Future<void> _requestNotificationPermission() async {
    try {
      await Permission.notification.request();
    } catch (_) {
      // Keep app usable even if notification permission API is unavailable.
    }
  }

  void _startPolling() {
    if (kDebugMode) {
      debugPrint("startPolling called");
    }
    if (_corePollTimer?.isActive == true && _historyPollTimer?.isActive == true) {
      return;
    }

    unawaited(_refreshCore(force: true));
    unawaited(_refreshHistory(silent: true, force: true));

    _corePollTimer ??= Timer.periodic(_kModePollInterval, (_) {
      if (!mounted) return;
      unawaited(_refreshCore(silent: true));
    });
    _historyPollTimer ??= Timer.periodic(_kHistoryPollInterval, (_) {
      if (!mounted) return;
      unawaited(_refreshHistory(silent: true));
    });
    _bluetoothPollTimer ??= Timer.periodic(_kBluetoothTickInterval, (_) {
      if (!mounted || _autoModeSetting != "bluetooth_auto") return;
      unawaited(_runBluetoothAutoTick());
    });
  }

  void _cancelAllPollingTimers() {
    _corePollTimer?.cancel();
    _historyPollTimer?.cancel();
    _bluetoothPollTimer?.cancel();
    _corePollTimer = null;
    _historyPollTimer = null;
    _bluetoothPollTimer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelAllPollingTimers();
    _tts.stop();
    super.dispose();
  }

  Future<void> _initBluetooth() async {
    await _bluetooth.loadSavedAnchor();
    _bluetoothPermissionGranted = await _bluetooth.ensurePermissions();
    _bluetooth.status.addListener(() {
      if (!mounted) return;
      setState(() {
        _bluetoothStatus = _bluetooth.status.value;
      });
    });
    _bluetooth.latestRssi.addListener(() {
      if (!mounted) return;
      setState(() {
        _lastRssi = _bluetooth.latestRssi.value;
      });
    });
    _bluetooth.lastReason.addListener(() {
      if (!mounted) return;
      setState(() {
        _bluetoothReason = _bluetooth.lastReason.value;
      });
    });
  }

  Future<void> _setupTts() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.48);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
  }

  Future<void> _triggerOutdoorAlert(ReminderModel reminder) async {
    final alertKey = "${reminder.id}-${reminder.timestamp}-${reminder.status}";
    if (_lastAlertKey == alertKey) return;
    _lastAlertKey = alertKey;

    try {
      if (await Vibration.hasVibrator()) {
        if (await Vibration.hasCustomVibrationsSupport()) {
          Vibration.vibrate(pattern: [0, 350, 200, 350, 200, 450], amplitude: 180);
        } else {
          Vibration.vibrate(duration: 800);
        }
      }
    } catch (_) {
      // Keep reminder flow active even if vibration plugin fails.
    }

    try {
      final message = reminder.message.trim().isNotEmpty
          ? reminder.message.trim()
          : "Please check your reminder now.";
      await _tts.speak("Reminder alert. ${reminder.title}. $message");
    } catch (_) {
      // Keep reminder flow active even if TTS fails.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _cancelAllPollingTimers();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _startPolling();
    }
  }

  Future<void> _runBluetoothAutoTick() async {
    if (_bluetoothTickInFlight) return;
    _bluetoothTickInFlight = true;
    try {
    if (_bluetooth.anchor == null) {
      setState(() {
        _bluetoothStatus = "anchor_not_configured";
      });
      return;
    }
    if (!_bluetoothPermissionGranted) {
      setState(() {
        _bluetoothStatus = "permission_denied";
        _bluetoothReason = "Bluetooth permission denied";
      });
      return;
    }

    final decision = await _bluetooth.evaluate(currentMode: _mode);
    if (!decision.shouldSwitch || decision.targetMode == null) return;
    try {
      final state = await _api.updateMode(
        mode: decision.targetMode!,
        source: "bluetooth_auto",
        deviceId: _bluetooth.anchor?.id,
        rssi: _lastRssi,
        reason: decision.reason,
      );
      setState(() {
        _mode = state.mode;
        _modeSource = state.source;
        _autoModeSetting = state.autoModeSetting;
        _bluetoothReason = decision.reason ?? "";
      });
    } catch (_) {
      // Avoid disrupting reminder polling if auto mode update fails.
    }
    } finally {
      _bluetoothTickInFlight = false;
    }
  }

  /// Fetches [getModeState] and [getLatestReminder] only.
  Future<void> _refreshCore({bool silent = false, bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastCoreRefresh != null &&
        now.difference(_lastCoreRefresh!) < _kModePollInterval) {
      if (kDebugMode) {
        debugPrint("refreshCore skipped due to throttle");
      }
      return;
    }
    if (_coreRefreshInFlight) return;
    _coreRefreshInFlight = true;
    _lastCoreRefresh = now;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = "";
      });
    }
    try {
      final sw = Stopwatch()..start();
      final modeState = await _api.getModeState();
      final latest = await _api.getLatestReminder().catchError((_) => _latest);
      if (kDebugMode) {
        debugPrint("refreshCore completed in ${sw.elapsedMilliseconds}ms");
      }
      if (!mounted) return;
      final shouldUpdate = _mode != modeState.mode ||
          _modeSource != modeState.source ||
          _autoModeSetting != modeState.autoModeSetting ||
          _latest?.id != latest?.id ||
          _latest?.status != latest?.status ||
          _error.isNotEmpty;
      if (!shouldUpdate) return;
      setState(() {
        _mode = modeState.mode;
        _modeSource = modeState.source;
        _autoModeSetting = modeState.autoModeSetting;
        _lastRssi = modeState.lastRssi ?? _lastRssi;
        _latest = latest;
        _error = "";
      });
      if (_autoModeSetting == "bluetooth_auto") {
        await _runBluetoothAutoTick();
      }
      if (modeState.mode == "outdoor" &&
          latest != null &&
          latest.status == "pending") {
        await _triggerOutdoorAlert(latest);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error =
            "Backend unreachable at ${ApiService.baseUrl}. If using a physical phone, run with --dart-define=API_BASE_URL=http://<PC_LAN_IP>:8000";
      });
    } finally {
      _coreRefreshInFlight = false;
      if (mounted && !silent) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _configureBluetoothAnchor() async {
    final granted = await _bluetooth.ensurePermissions();
    _bluetoothPermissionGranted = granted;
    if (!granted) {
      setState(() {
        _bluetoothStatus = "permission_denied";
        _bluetoothReason = "Bluetooth permission denied";
      });
      return;
    }
    final results = await _bluetooth.scanDevices();
    if (!mounted) return;
    if (results.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      builder: (bottomSheetContext) => SafeArea(
        child: ListView(
          children: [
            const ListTile(
              title: Text("Select Indoor PC/Laptop Bluetooth Device"),
            ),
            ...results.map((result) {
              final label = result.device.platformName.isNotEmpty
                  ? result.device.platformName
                  : "Unknown device";
              return ListTile(
                title: Text(label),
                subtitle: Text(result.device.remoteId.str),
                trailing: Text("${result.rssi} dBm"),
                onTap: () {
                  final selected = BluetoothAnchorDevice(
                    id: result.device.remoteId.str,
                    name: label,
                  );
                  Navigator.of(bottomSheetContext).pop();
                  _bluetooth.saveAnchor(selected);
                  if (!mounted) return;
                  setState(() {
                    _bluetoothStatus = "anchor_configured";
                  });
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  /// [getHistory] only.
  Future<void> _refreshHistory({bool silent = false, bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastHistoryRefresh != null &&
        now.difference(_lastHistoryRefresh!) < _kHistoryPollInterval) {
      if (kDebugMode) {
        debugPrint("refreshHistory skipped due to throttle");
      }
      return;
    }
    if (_historyRefreshInFlight) return;
    _historyRefreshInFlight = true;
    _lastHistoryRefresh = now;
    try {
      final sw = Stopwatch()..start();
      final history = await _api.getHistory(limit: 30);
      if (!mounted) return;
      if (kDebugMode) {
        debugPrint("refreshHistory completed in ${sw.elapsedMilliseconds}ms");
      }
      final shouldUpdate =
          _history.length != history.length ||
          (_history.isNotEmpty &&
              history.isNotEmpty &&
              (_history.first.id != history.first.id ||
                  _history.first.status != history.first.status)) ||
          (_history.isEmpty && history.isNotEmpty);
      if (!shouldUpdate && silent) return;
      setState(() {
        _history = history;
      });
      await OutdoorAlarmService.syncFromHistory(history);
      if (kDebugMode) {
        debugPrint("reminder synced from history: count=${history.length}");
      }
    } catch (_) {
      // Keep last cached history without interrupting mode/latest UX.
    } finally {
      _historyRefreshInFlight = false;
    }
  }

  Future<void> _acknowledge(ReminderModel reminder) async {
    await _api.acknowledgeReminder(reminder.id);
    await OutdoorAlarmService.cancelReminder(reminder.id);
    await _refreshCore();
    await _refreshHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Outdoor Reminder Simulator"),
        actions: [
          IconButton(
            onPressed: () async {
              await _refreshCore();
              await _refreshHistory();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: [
                  ModeBadge(mode: _mode),
                  const SizedBox(height: 14),
                  if (_error.isNotEmpty) ...[
                    Text(
                      _error,
                      style: const TextStyle(color: Colors.red),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    "Backend: ${ApiService.baseUrl}",
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "Mode source: $_modeSource • Auto setting: $_autoModeSetting",
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "Bluetooth: $_bluetoothStatus • RSSI: ${_lastRssi != null ? "$_lastRssi dBm" : "N/A"}",
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  if (_bluetooth.anchor != null)
                    Text(
                      "Anchor: ${_bluetooth.anchor!.name} (${_bluetooth.anchor!.id})",
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  if (_bluetoothReason.isNotEmpty)
                    Text(
                      "Reason: $_bluetoothReason",
                      style: const TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ElevatedButton(
                        onPressed: _configureBluetoothAnchor,
                        child: const Text("Configure PC Bluetooth"),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          final next =
                              _autoModeSetting == "bluetooth_auto" ? "manual" : "bluetooth_auto";
                          try {
                            final state = await _api.updateMode(
                              mode: _mode,
                              source: "manual",
                              autoModeSetting: next,
                              deviceId: _bluetooth.anchor?.id,
                              rssi: _lastRssi,
                              reason: "Auto mode setting changed from mobile app",
                            );
                            if (!mounted) return;
                            setState(() {
                              _autoModeSetting = state.autoModeSetting;
                              _modeSource = state.source;
                            });
                          } catch (_) {
                            if (!mounted) return;
                            setState(() {
                              _error = "Failed to update auto mode setting.";
                            });
                          }
                        },
                        child: Text(
                          _autoModeSetting == "bluetooth_auto"
                              ? "Disable Bluetooth Auto Mode"
                              : "Enable Bluetooth Auto Mode",
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    "Latest Reminder",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  if (_latest == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text("No outdoor reminders yet."),
                    ),
                  if (_latest != null)
                    ReminderCard(
                      reminder: _latest!,
                      onAcknowledge: () => _acknowledge(_latest!),
                    ),
                  const SizedBox(height: 10),
                  const Text(
                    "History",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  ..._history.map(
                    (item) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.title),
                      subtitle: Text(
                        "${formatTimestampToLocal(item.timestamp)} • ${item.status}",
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
