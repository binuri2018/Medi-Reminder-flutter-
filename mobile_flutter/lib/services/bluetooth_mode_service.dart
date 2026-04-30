import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter_blue_plus/flutter_blue_plus.dart";
import "package:permission_handler/permission_handler.dart";

import "ble_mode_controller.dart";

class BluetoothModeService {
  static const Duration _scanDuration = Duration(seconds: 5);
  static const Duration _restBetweenScans = Duration(seconds: 5);

  final ValueNotifier<String> status = ValueNotifier<String>("idle");
  final ValueNotifier<int?> latestRssi = ValueNotifier<int?>(null);
  final ValueNotifier<String> lastReason = ValueNotifier<String>("");

  final BleModeController _bleMode = BleModeController();

  List<ScanResult> _scanSnapshot = <ScanResult>[];
  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  Timer? _scanPulseTimer;
  bool _scanLoopSuspended = false;
  bool _scanPulseInFlight = false;

  /// Grants BT scan/connect + **location while in use**. On Android (all
  /// targeted API levels today), BLE scanning for unpaired devices normally
  /// requires coarse/fine location; denying **Location** still makes this
  /// fail even when "Bluetooth" looks enabled in Quick Settings.
  Future<({bool granted, String? deniedHint})> ensurePermissions() async {
    final scan = await Permission.bluetoothScan.request();
    if (!scan.isGranted) {
      return (
        granted: false,
        deniedHint:
            "Allow “Nearby devices” / Bluetooth scan in system settings "
            "(Settings → Apps → this app → Permissions).",
      );
    }
    final connect = await Permission.bluetoothConnect.request();
    if (!connect.isGranted) {
      return (
        granted: false,
        deniedHint:
            "Allow Bluetooth connect (pairing / connection) for this app in Settings → Permissions.",
      );
    }
    final location = await Permission.locationWhenInUse.request();
    if (!location.isGranted) {
      return (
        granted: false,
        deniedHint:
            "Location must be allowed while using the app — Android uses it for "
            "Bluetooth low-energy scans. Enable Location in Settings → Permissions.",
      );
    }
    return (granted: true, deniedHint: null);
  }

  void _ensureScanResultsListener() {
    _scanResultsSub ??= FlutterBluePlus.scanResults.listen(
      (results) => _scanSnapshot = List<ScanResult>.from(results),
    );
  }

  /// Single BLE duty cycle: [_scanDuration] scan session, then [_restBetweenScans] rest.
  /// Only one pulse timer at a time; [evaluate] does not start scans.
  void _ensureScanPulseLoop() {
    if (_scanPulseInFlight) return;
    final t = _scanPulseTimer;
    if (t != null && t.isActive) return;
    _scanLoopSuspended = false;
    _kickScanPulseAfter(Duration.zero);
  }

  void _kickScanPulseAfter(Duration delay) {
    _scanPulseTimer?.cancel();
    _scanPulseTimer = Timer(delay, () {
      unawaited(_scanPulseTick());
    });
  }

  Future<void> _scanPulseTick() async {
    if (_scanLoopSuspended) return;
    _scanPulseInFlight = true;
    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        _kickScanPulseAfter(_restBetweenScans);
        return;
      }
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        _kickScanPulseAfter(_restBetweenScans);
        return;
      }

      if (FlutterBluePlus.isScanningNow) {
        if (kDebugMode) {
          debugPrint("BLE scan skipped: already scanning");
        }
        _kickScanPulseAfter(_restBetweenScans);
        return;
      }

      try {
        if (kDebugMode) {
          debugPrint("BLE scan started");
        }
        await FlutterBluePlus.startScan(timeout: _scanDuration);

        await Future<void>.delayed(_scanDuration);
        while (FlutterBluePlus.isScanningNow) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (kDebugMode) {
          debugPrint("BLE scan stopped");
        }
      } catch (_) {
        if (kDebugMode) {
          debugPrint("BLE scan stopped");
        }
      }

      _kickScanPulseAfter(_restBetweenScans);
    } finally {
      _scanPulseInFlight = false;
    }
  }

  /// Stops the scan/rest timer chain (explicit shutdown).
  void stopBleScanLoop() {
    _scanLoopSuspended = true;
    _scanPulseTimer?.cancel();
    _scanPulseTimer = null;
    _scanPulseInFlight = false;
    unawaited(_scanResultsSub?.cancel());
    _scanResultsSub = null;
    _scanSnapshot = <ScanResult>[];
    unawaited(FlutterBluePlus.stopScan());
  }

  /// Advertiser beacon: match [BleModeController.targetBeaconName] via device
  /// platform name or AD flag name — not MAC ([BluetoothDevice.remoteId]).
  ScanResult? _findTargetBeacon(List<ScanResult> results) {
    const trimmed = BleModeController.targetBeaconName;
    ScanResult? best;
    for (final r in results) {
      final dn = r.device.platformName.trim();
      final adv = r.advertisementData.advName.trim();
      if (dn != trimmed && adv != trimmed) continue;
      if (best == null || r.rssi > best.rssi) {
        best = r;
      }
    }
    return best;
  }

  Future<BluetoothDecision> evaluate({
    required String currentMode,
  }) async {
    if (!await FlutterBluePlus.isSupported) {
      status.value = "bluetooth_not_supported";
      return const BluetoothDecision.keep();
    }
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      status.value = "bluetooth_off";
      return const BluetoothDecision.keep();
    }

    _ensureScanResultsListener();
    _ensureScanPulseLoop();

    final results = List<ScanResult>.from(_scanSnapshot);
    final match = _findTargetBeacon(results);

    final now = DateTime.now();
    final beaconDetected = match != null;

    if (match != null) {
      latestRssi.value = match.rssi;
      status.value =
          match.device.isConnected ? "connected" : "detected";

      final name = match.device.platformName.trim().isNotEmpty
          ? match.device.platformName.trim()
          : match.advertisementData.advName.trim();
      if (kDebugMode) {
        debugPrint("BLE beacon found: name=$name rssi=${match.rssi}");
      }
    } else {
      latestRssi.value = null;
      status.value = "not_found";
    }

    final BleModeOutcome o = _bleMode.update(
      now: now,
      currentMode: currentMode,
      beaconDetected: beaconDetected,
      rssi: match?.rssi,
    );

    if (o.shouldSwitch && o.targetMode != null && o.reason != null) {
      lastReason.value = o.reason!;
      return BluetoothDecision.switchMode(
        targetMode: o.targetMode!,
        reason: o.reason!,
      );
    }
    return const BluetoothDecision.keep();
  }
}

class BluetoothDecision {
  final bool shouldSwitch;
  final String? targetMode;
  final String? reason;

  const BluetoothDecision.keep()
      : shouldSwitch = false,
        targetMode = null,
        reason = null;

  BluetoothDecision.switchMode({
    required String targetMode,
    required String reason,
  })  : shouldSwitch = true,
        targetMode = targetMode,
        reason = reason;
}
