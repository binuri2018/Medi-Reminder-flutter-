import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter_blue_plus/flutter_blue_plus.dart";
import "package:permission_handler/permission_handler.dart";
import "package:shared_preferences/shared_preferences.dart";

class BluetoothAnchorDevice {
  final String id;
  final String name;

  const BluetoothAnchorDevice({required this.id, required this.name});
}

class BluetoothModeService {
  static const String _anchorIdKey = "bt_anchor_id";
  static const String _anchorNameKey = "bt_anchor_name";
  static const int indoorThreshold = -70;
  static const int outdoorThreshold = -85;
  static const Duration indoorConfirmDuration = Duration(seconds: 25);
  static const Duration outdoorConfirmDuration = Duration(seconds: 45);

  final ValueNotifier<String> status = ValueNotifier<String>("idle");
  final ValueNotifier<int?> latestRssi = ValueNotifier<int?>(null);
  final ValueNotifier<String> lastReason = ValueNotifier<String>("");

  DateTime? _indoorCandidateSince;
  DateTime? _outdoorCandidateSince;
  BluetoothAnchorDevice? _anchor;

  BluetoothAnchorDevice? get anchor => _anchor;

  Future<void> loadSavedAnchor() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_anchorIdKey);
    final name = prefs.getString(_anchorNameKey);
    if (id != null && id.isNotEmpty) {
      _anchor = BluetoothAnchorDevice(id: id, name: name ?? "Configured PC");
    }
  }

  Future<void> saveAnchor(BluetoothAnchorDevice anchor) async {
    _anchor = anchor;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_anchorIdKey, anchor.id);
    await prefs.setString(_anchorNameKey, anchor.name);
  }

  Future<bool> ensurePermissions() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    final location = await Permission.locationWhenInUse.request();
    return scan.isGranted && connect.isGranted && location.isGranted;
  }

  Future<List<ScanResult>> scanDevices() async {
    if (!await FlutterBluePlus.isSupported) {
      status.value = "bluetooth_not_supported";
      return [];
    }
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      status.value = "bluetooth_off";
      return [];
    }
    status.value = "scanning";
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    final results = await FlutterBluePlus.scanResults.first;
    status.value = results.isEmpty ? "not_found" : "scan_complete";
    return results;
  }

  Future<BluetoothDecision> evaluate({
    required String currentMode,
  }) async {
    if (_anchor == null) {
      status.value = "anchor_not_configured";
      return const BluetoothDecision.keep();
    }
    if (!await FlutterBluePlus.isSupported) {
      status.value = "bluetooth_not_supported";
      return const BluetoothDecision.keep();
    }
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      status.value = "bluetooth_off";
      return const BluetoothDecision.keep();
    }

    status.value = "scanning";
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    final results = await FlutterBluePlus.scanResults.first;
    final match = _findAnchorResult(results);
    if (match == null) {
      status.value = "not_found";
      latestRssi.value = null;
      return _evaluateOutdoorCandidate(
        currentMode: currentMode,
        reason: "Bluetooth anchor not found during scan",
      );
    }

    final rssi = match.rssi;
    latestRssi.value = rssi;
    final connected = match.device.isConnected;
    status.value = connected ? "connected" : "detected";
    if (kDebugMode) {
      debugPrint("Bluetooth anchor detected: id=${match.device.remoteId.str} rssi=$rssi connected=$connected");
    }

    if (connected || rssi >= indoorThreshold) {
      return _evaluateIndoorCandidate(currentMode: currentMode);
    }
    if (rssi <= outdoorThreshold) {
      return _evaluateOutdoorCandidate(
        currentMode: currentMode,
        reason: "RSSI below outdoor threshold",
      );
    }

    _indoorCandidateSince = null;
    _outdoorCandidateSince = null;
    return const BluetoothDecision.keep();
  }

  ScanResult? _findAnchorResult(List<ScanResult> results) {
    if (_anchor == null) return null;
    for (final result in results) {
      if (result.device.remoteId.str == _anchor!.id) {
        return result;
      }
      if (_anchor!.name.isNotEmpty && result.device.platformName == _anchor!.name) {
        return result;
      }
    }
    return null;
  }

  BluetoothDecision _evaluateIndoorCandidate({required String currentMode}) {
    _outdoorCandidateSince = null;
    _indoorCandidateSince ??= DateTime.now();
    final stableFor = DateTime.now().difference(_indoorCandidateSince!);
    if (stableFor >= indoorConfirmDuration && currentMode != "indoor") {
      lastReason.value = "Bluetooth strong signal detected";
      _indoorCandidateSince = null;
      return BluetoothDecision.switchMode(
        targetMode: "indoor",
        reason: lastReason.value,
      );
    }
    return const BluetoothDecision.keep();
  }

  BluetoothDecision _evaluateOutdoorCandidate({
    required String currentMode,
    required String reason,
  }) {
    _indoorCandidateSince = null;
    _outdoorCandidateSince ??= DateTime.now();
    final stableFor = DateTime.now().difference(_outdoorCandidateSince!);
    if (stableFor >= outdoorConfirmDuration && currentMode != "outdoor") {
      lastReason.value = reason == "RSSI below outdoor threshold"
          ? "RSSI below outdoor threshold"
          : "Bluetooth lost for confirmed duration";
      _outdoorCandidateSince = null;
      return BluetoothDecision.switchMode(
        targetMode: "outdoor",
        reason: lastReason.value,
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

  const BluetoothDecision.switchMode({
    required this.targetMode,
    required this.reason,
  }) : shouldSwitch = true;
}
