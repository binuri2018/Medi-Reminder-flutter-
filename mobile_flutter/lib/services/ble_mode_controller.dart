/// RSSI-based indoor/outdoor hysteresis for a named BLE advertiser beacon.
/// Does not scan — callers feed RSSI updates from existing [flutter_blue_plus] flows.
class BleModeOutcome {
  final bool shouldSwitch;
  final String? targetMode;
  final String? reason;

  const BleModeOutcome.keep()
      : shouldSwitch = false,
        targetMode = null,
        reason = null;

  BleModeOutcome.change({
    required String targetMode,
    required String reason,
  })  : shouldSwitch = true,
        targetMode = targetMode,
        reason = reason;
}

class BleModeController {
  static const int enterIndoorRssi = -78;
  static const int exitIndoorRssi = -88;
  static const Duration stabilityDuration = Duration(seconds: 3);
  static const Duration noSignalTimeout = Duration(seconds: 6);
  static const int rssiWindowSize = 5;
  static const Duration cooldownDuration = Duration(seconds: 3);

  /// Match [ScanResult.device.platformName] or [AdvertisementData.advName].
  static const String targetBeaconName = "Binuri's A15";

  final List<int> _rssiWindow = <int>[];

  DateTime? _sessionStart;
  DateTime? _lastBeaconSeen;
  DateTime? _indoorStabilityStarted;
  DateTime? _outdoorStabilityStarted;
  DateTime? _cooldownUntil;

  void reset() {
    _rssiWindow.clear();
    _sessionStart = null;
    _lastBeaconSeen = null;
    _indoorStabilityStarted = null;
    _outdoorStabilityStarted = null;
    _cooldownUntil = null;
  }

  bool _inCooldown(DateTime now) =>
      _cooldownUntil != null && now.isBefore(_cooldownUntil!);

  double? _averageRssi() {
    if (_rssiWindow.isEmpty) return null;
    var sum = 0;
    for (final v in _rssiWindow) {
      sum += v;
    }
    return sum / _rssiWindow.length;
  }

  void _pushRssi(int rssi) {
    _rssiWindow.add(rssi);
    while (_rssiWindow.length > rssiWindowSize) {
      _rssiWindow.removeAt(0);
    }
  }

  void _enterCooldown(DateTime now) {
    _cooldownUntil = now.add(cooldownDuration);
  }

  BleModeOutcome update({
    required DateTime now,
    required String currentMode,
    required bool beaconDetected,
    int? rssi,
  }) {
    _sessionStart ??= now;

    if (_inCooldown(now)) {
      return const BleModeOutcome.keep();
    }

    final normalized = currentMode.trim().toLowerCase();
    final indoor = normalized == "indoor";
    final outdoor = normalized == "outdoor";
    if (!indoor && !outdoor) {
      return const BleModeOutcome.keep();
    }

    if (beaconDetected) {
      final rss = rssi;
      if (rss != null) {
        _pushRssi(rss);
        _lastBeaconSeen = now;
      }
    }

    if (!beaconDetected) {
      final reference = _lastBeaconSeen ?? _sessionStart!;
      if (now.difference(reference) >= noSignalTimeout) {
        if (outdoor) {
          _rssiWindow.clear();
          _indoorStabilityStarted = null;
          _outdoorStabilityStarted = null;
          return const BleModeOutcome.keep();
        }
        _rssiWindow.clear();
        _indoorStabilityStarted = null;
        _outdoorStabilityStarted = null;
        _enterCooldown(now);
        return BleModeOutcome.change(
          targetMode: "outdoor",
          reason:
              "Beacon not detected (${noSignalTimeout.inSeconds}s no signal)",
        );
      }
      return const BleModeOutcome.keep();
    }

    if (beaconDetected && rssi == null) {
      return const BleModeOutcome.keep();
    }

    final avg = _averageRssi();
    if (avg == null) {
      return const BleModeOutcome.keep();
    }

    if (outdoor) {
      if (avg > enterIndoorRssi) {
        _indoorStabilityStarted ??= now;
        _outdoorStabilityStarted = null;
      } else {
        _indoorStabilityStarted = null;
      }
      if (_indoorStabilityStarted != null &&
          now.difference(_indoorStabilityStarted!) >= stabilityDuration) {
        _indoorStabilityStarted = null;
        _enterCooldown(now);
        return BleModeOutcome.change(
          targetMode: "indoor",
          reason:
              "Avg RSSI above $enterIndoorRssi dBm for ${stabilityDuration.inSeconds}s",
        );
      }
    }

    if (indoor) {
      if (avg < exitIndoorRssi) {
        _outdoorStabilityStarted ??= now;
        _indoorStabilityStarted = null;
      } else {
        _outdoorStabilityStarted = null;
      }
      if (_outdoorStabilityStarted != null &&
          now.difference(_outdoorStabilityStarted!) >= stabilityDuration) {
        _outdoorStabilityStarted = null;
        _enterCooldown(now);
        return BleModeOutcome.change(
          targetMode: "outdoor",
          reason:
              "Avg RSSI below $exitIndoorRssi dBm for ${stabilityDuration.inSeconds}s",
        );
      }
    }

    return const BleModeOutcome.keep();
  }
}
