import "package:flutter/material.dart";
import "dart:async";
import "package:flutter/foundation.dart";
import "package:flutter_tts/flutter_tts.dart";
import "package:google_fonts/google_fonts.dart";
import "package:permission_handler/permission_handler.dart";
import "package:speech_to_text/speech_to_text.dart" as stt;
import "package:vibration/vibration.dart";

import "../config/api_config.dart";
import "../models/reminder_model.dart";
import "../services/api_service.dart";
import "../services/bluetooth_mode_service.dart";
import "../services/outdoor_alarm_service.dart";
import "../theme/app_theme.dart";
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
  final stt.SpeechToText _speech = stt.SpeechToText();
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
  /// History list sync. Kept reasonably tight so multiple future reminders
  /// (not only `/latest`) still reach [OutdoorAlarmService] quickly. The
  /// critical path for the current reminder is `_refreshCore` every 5s.
  static const Duration _kHistoryPollInterval = Duration(seconds: 10);
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
  /// Fingerprint of the last history list we fed into [OutdoorAlarmService.syncFromHistory].
  /// Used so silent polls still reconcile alarms when the list changes in ways the UI
  /// `shouldUpdate` heuristic used to miss, without re-running sync on every tick when
  /// nothing changed.
  String? _lastHistoryAlarmSyncKey;

  // Voice command pipeline state. `_speechActive` makes the listener
  // single-shot per alert, while `_speechInitTried` avoids re-initializing the
  // STT engine on every reminder.
  bool _speechAvailable = false;
  bool _speechInitTried = false;
  bool _speechActive = false;
  String? _voiceCommandReminderId;

  /// Shared init future so [FlutterTts.speak] never runs before the Android
  /// TextToSpeech engine has bound (common cause of silent TTS).
  late final Future<void> _ttsInitFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ttsInitFuture = _setupTts();
    _initBluetooth();
    _startPolling();
    // Permissions must be requested ONCE, sequentially, after the activity
    // is attached - never from inside polling/sync code. permission_handler
    // serializes to a single in-flight request and rejects parallel calls.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runOneTimePermissionFlow());
      _onPendingTapChanged();
    });
    // Surface any reminder the user just tapped on (foreground tap, app
    // relaunch from notification, or a queued tap restored from prefs).
    OutdoorAlarmService.pendingTapNotifier.addListener(_onPendingTapChanged);
  }

  bool _permissionsRequested = false;

  Future<void> _runOneTimePermissionFlow() async {
    if (_permissionsRequested) return;
    _permissionsRequested = true;
    // Centralised permission flow: every permission is requested in series so
    // package:permission_handler never sees overlapping requests. This is the
    // only place ensurePermissions() should be invoked from on the UI thread.
    await OutdoorAlarmService.ensurePermissions();
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
    OutdoorAlarmService.pendingTapNotifier.removeListener(_onPendingTapChanged);
    _cancelAllPollingTimers();
    _tts.stop();
    if (_speech.isListening) {
      unawaited(_speech.stop());
    }
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
    try {
      await _tts.setLanguage("en-US");
      await _tts.setSpeechRate(0.48);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      // Flush queue so a stale utterance cannot block the next speak().
      try {
        await _tts.setQueueMode(0);
      } catch (_) {
        // Not all platforms implement queue mode.
      }
      // Make `await _tts.speak(...)` actually wait for completion so we can
      // safely chain speech recognition after TTS.
      try {
        await _tts.awaitSpeakCompletion(true);
      } catch (_) {
        // Older flutter_tts builds may not support this; safe to ignore.
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("_setupTts failed: $e");
      }
    }
  }

  /// Plays the reminder's voice + vibration locally and then opens a short
  /// safe window to listen for a "done" voice command.
  ///
  /// `force` is set to `true` when called from a notification tap so the user
  /// who just opened the app reliably hears the message even if the same
  /// reminder was already alerted earlier in the foreground polling pass.
  Future<void> _triggerOutdoorAlert(
    ReminderModel reminder, {
    bool force = false,
  }) async {
    // Critical guard: never alert a non-pending reminder, even if a stale
    // foreground poll observed it before the status flip propagated.
    if (!isReminderPending(reminder.status)) return;

    final alertKey = "${reminder.id}-${reminder.timestamp}-${reminder.status}";
    if (!force && _lastAlertKey == alertKey) return;
    _lastAlertKey = alertKey;

    // Foreground notification fallback: keeps popup behavior alive even when
    // history scheduling skipped a due reminder as stale.
    await OutdoorAlarmService.postForegroundDueNotification(reminder);
    if (!OutdoorAlarmService.shouldPlayInAppVoice(reminder)) {
      return;
    }

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

    final spokenMessage = reminder.message.trim().isNotEmpty
        ? reminder.message.trim()
        : (reminder.title.trim().isNotEmpty
            ? reminder.title.trim()
            : "Please check your reminder now.");
    final spokenTitle = reminder.title.trim().isNotEmpty
        ? reminder.title.trim()
        : "Outdoor reminder";

    final utterance = "Reminder alert. $spokenTitle. $spokenMessage";
    try {
      await _ttsInitFuture;
      // Cold start / activity resume: engine and audio route may still be
      // settling; a short yield fixes "vibration only" on some Samsung builds.
      if (force) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      try {
        await _tts.stop();
      } catch (_) {}
      await _tts.setLanguage("en-US");
      await _tts.setSpeechRate(0.48);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      try {
        await _tts.awaitSpeakCompletion(true);
      } catch (_) {}
      try {
        await _tts.setQueueMode(0);
      } catch (_) {}
      final dynamic speakResult = await _tts.speak(utterance);
      if (kDebugMode) {
        debugPrint(
          "TTS speak done: force=$force id=${reminder.id} result=$speakResult",
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("TTS speak failed: id=${reminder.id} err=$e");
      }
    }

    // Mic / STT can steal audio focus on some devices if we start listening
    // in the same frame as TTS teardown — brief gap keeps voice audible.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    // Voice "done" listening only makes sense once TTS has stopped using
    // the audio output, otherwise STT will pick up our own playback.
    if (!mounted) return;
    unawaited(_listenForDoneCommand(reminder));
  }

  /// Opens a short STT window to detect "done"/"completed"/"finish"/"finished".
  /// Runs at most one window per reminder ID so a UI rebuild cannot stack
  /// multiple recognizers.
  Future<void> _listenForDoneCommand(ReminderModel reminder) async {
    if (_speechActive) return;
    if (_voiceCommandReminderId == reminder.id) return;
    _voiceCommandReminderId = reminder.id;
    _speechActive = true;
    try {
      // Lazy mic permission so we never prompt unless a reminder fires.
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        if (kDebugMode) {
          debugPrint("voice command skipped: mic permission=$micStatus");
        }
        return;
      }

      if (!_speechInitTried) {
        _speechInitTried = true;
        try {
          _speechAvailable = await _speech.initialize(
            onStatus: (status) {
              if (kDebugMode) {
                debugPrint("speech_to_text status: $status");
              }
            },
            onError: (error) {
              if (kDebugMode) {
                debugPrint("speech_to_text error: ${error.errorMsg}");
              }
            },
          );
        } catch (e) {
          _speechAvailable = false;
          if (kDebugMode) {
            debugPrint("speech_to_text init failed: $e");
          }
        }
      }
      if (!_speechAvailable) return;
      if (_speech.isListening) return;

      var matched = false;
      await _speech.listen(
        listenFor: const Duration(seconds: 6),
        pauseFor: const Duration(seconds: 3),
        listenOptions: stt.SpeechListenOptions(partialResults: true),
        localeId: "en_US",
        onResult: (result) async {
          if (matched) return;
          if (!_isDoneCommand(result.recognizedWords)) return;
          matched = true;
          if (kDebugMode) {
            debugPrint(
              "voice 'done' detected: text='${result.recognizedWords}' "
              "id=${reminder.id}",
            );
          }
          try {
            await _speech.stop();
          } catch (_) {
            // intentional swallow
          }
          if (!mounted) return;
          await _acknowledge(reminder);
        },
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint("voice command failed: $e");
      }
    } finally {
      _speechActive = false;
    }
  }

  bool _isDoneCommand(String raw) {
    final text = raw.toLowerCase().trim();
    if (text.isEmpty) return false;
    const triggers = ["done", "completed", "complete", "finish", "finished"];
    for (final word in triggers) {
      if (text == word) return true;
      if (text.contains(" $word") || text.startsWith("$word ")) return true;
      if (text.contains("$word.") || text.endsWith(" $word")) return true;
    }
    return false;
  }

  /// Reacts to taps on outdoor reminder notifications. Pulls the pending
  /// reminder, surfaces it on screen, and runs the live alert with `force`
  /// so the user reliably hears the message right after opening the app.
  void _onPendingTapChanged() {
    final reminder = OutdoorAlarmService.pendingTapNotifier.value;
    if (reminder == null) return;
    if (!mounted) return;
    if (kDebugMode) {
      debugPrint("HomeScreen received pending tap for reminder=${reminder.id}");
    }
    setState(() {
      // Make sure the tapped reminder is the one rendered in the "Latest"
      // card; the next backend poll will replace it if anything changed.
      _latest = reminder;
    });
    // Only fire the alert if the reminder is still pending. If the user
    // tapped a stale notification for an already-acknowledged reminder we
    // simply consume the tap without speaking again.
    if (isReminderPending(reminder.status)) {
      unawaited(_triggerOutdoorAlert(reminder, force: true));
    }
    unawaited(OutdoorAlarmService.consumePendingTap());
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

      // Exact-time scheduling is driven by FCM data messages (see
      // [FcmService.syncReminderFromMessage]). Core poll mirrors UI state and
      // adds a foreground fallback so a due latest reminder still pops even if
      // history scheduling marked it stale or was delayed. History sync +
      // WorkManager remain the backup schedulers.
      if (modeState.mode.trim().toLowerCase() == "outdoor" &&
          latest != null &&
          isReminderPending(latest.status) &&
          OutdoorAlarmService.shouldAlertLatestInForeground(latest)) {
        unawaited(_triggerOutdoorAlert(latest));
      }

      final shouldUpdate = _mode != modeState.mode ||
          _modeSource != modeState.source ||
          _autoModeSetting != modeState.autoModeSetting ||
          _latest?.id != latest?.id ||
          _latest?.timestamp != latest?.timestamp ||
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
      isScrollControlled: true,
      builder: (bottomSheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (ctx, scrollController) => DecoratedBox(
          decoration: const BoxDecoration(
            color: AppColors.slateCard,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                child: Text(
                  "Choose your PC",
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  "Pick the Bluetooth device that represents your indoor computer so proximity can switch modes.",
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final result = results[index];
                    final label = result.device.platformName.isNotEmpty
                        ? result.device.platformName
                        : "Unknown device";
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Material(
                        color: AppColors.slateBg,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
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
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.bluetooth_rounded,
                                  color: AppColors.tealDeep,
                                  size: 28,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        label,
                                        style: GoogleFonts.plusJakartaSans(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        result.device.remoteId.str,
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 12,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.tealDeep.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    "${result.rssi} dBm",
                                    style: GoogleFonts.plusJakartaSans(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: AppColors.tealDeep,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _historyAlarmSyncKey(List<ReminderModel> list) {
    if (list.isEmpty) return "";
    return list
        .map(
          (r) =>
              "${r.id}|${r.timestamp}|${r.status}|${r.mode.trim().toLowerCase()}",
        )
        .join(";");
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
                  _history.first.status != history.first.status ||
                  _history.first.timestamp != history.first.timestamp)) ||
          (_history.isEmpty && history.isNotEmpty);
      if (shouldUpdate || !silent) {
        setState(() {
          _history = history;
        });
      }
      final alarmSyncKey = _historyAlarmSyncKey(history);
      if (force || alarmSyncKey != _lastHistoryAlarmSyncKey) {
        await OutdoorAlarmService.syncFromHistory(history);
        _lastHistoryAlarmSyncKey = alarmSyncKey;
      }
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

  Future<void> _onPullRefresh() async {
    await _refreshCore(force: true);
    await _refreshHistory(silent: true, force: true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: _loading
          ? _LoadingHero(scheme: scheme)
          : RefreshIndicator(
              color: scheme.primary,
              onRefresh: _onPullRefresh,
              edgeOffset: 120,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  SliverAppBar.large(
                    floating: false,
                    pinned: true,
                    expandedHeight: 108,
                    backgroundColor: AppColors.slateBg,
                    surfaceTintColor: Colors.transparent,
                    flexibleSpace: FlexibleSpaceBar(
                      titlePadding: const EdgeInsetsDirectional.only(
                        start: 20,
                        bottom: 14,
                      ),
                      title: Text(
                        "Reminders",
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      background: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              AppColors.tealMuted.withValues(alpha: 0.14),
                              AppColors.slateBg,
                            ],
                          ),
                        ),
                      ),
                    ),
                    actions: [
                      if (!kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.android)
                        IconButton.filledTonal(
                          onPressed: () async {
                            await OutdoorAlarmService
                                .openExactAlarmPermissionSettings();
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  "Turn on Alarms & reminders for this app, "
                                  "then use the back button to return.",
                                ),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          icon: const Icon(Icons.alarm_on_outlined),
                          tooltip: "Exact alarms (on-time reminders)",
                        ),
                      IconButton.filledTonal(
                        onPressed: () async {
                          await _refreshCore(force: true);
                          await _refreshHistory(silent: true, force: true);
                        },
                        icon: const Icon(Icons.refresh_rounded),
                        tooltip: "Refresh",
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        ModeBadge(mode: _mode),
                        const SizedBox(height: 20),
                        if (ApiConfig.isMisconfigured) ...[
                          const _ConfigWarningCard(url: ApiConfig.baseUrl),
                          const SizedBox(height: 16),
                        ],
                        if (_error.isNotEmpty) ...[
                          _ErrorBanner(message: _error),
                          const SizedBox(height: 16),
                        ],
                        _ConnectionStatusCard(
                          backendUrl: ApiService.baseUrl,
                          modeSource: _modeSource,
                          autoModeSetting: _autoModeSetting,
                          bluetoothStatus: _bluetoothStatus,
                          rssi: _lastRssi,
                          anchorName: _bluetooth.anchor?.name,
                          anchorId: _bluetooth.anchor?.id,
                          bluetoothReason: _bluetoothReason,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.tonalIcon(
                                onPressed: _configureBluetoothAnchor,
                                icon: const Icon(Icons.bluetooth_searching_rounded),
                                label: const Text("Link PC"),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  final next = _autoModeSetting == "bluetooth_auto"
                                      ? "manual"
                                      : "bluetooth_auto";
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
                                icon: Icon(
                                  _autoModeSetting == "bluetooth_auto"
                                      ? Icons.bluetooth_disabled_rounded
                                      : Icons.bluetooth_connected_rounded,
                                ),
                                label: Text(
                                  _autoModeSetting == "bluetooth_auto"
                                      ? "Auto off"
                                      : "Auto mode",
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        const _SectionTitle(
                          icon: Icons.notifications_active_outlined,
                          title: "Active reminder",
                          subtitle: "Outdoor alerts & voice apply here",
                        ),
                        const SizedBox(height: 12),
                        if (_latest == null)
                          const _EmptyLatestCard()
                        else
                          ReminderCard(
                            reminder: _latest!,
                            onAcknowledge: () => _acknowledge(_latest!),
                          ),
                        const SizedBox(height: 28),
                        _SectionTitle(
                          icon: Icons.history_rounded,
                          title: "History",
                          subtitle:
                              "${_history.length} ${_history.length == 1 ? "item" : "items"}",
                        ),
                        const SizedBox(height: 12),
                        if (_history.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                "No history yet.",
                                style: GoogleFonts.plusJakartaSans(
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          )
                        else
                          ..._history.map(
                            (item) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _HistoryTile(reminder: item),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _LoadingHero extends StatelessWidget {
  const _LoadingHero({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.tealMuted.withValues(alpha: 0.2),
            AppColors.slateBg,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              "Loading your reminders…",
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w600,
                fontSize: 16,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.tealDeep, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                subtitle,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyLatestCard extends StatelessWidget {
  const _EmptyLatestCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.slateCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.textSecondary.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.event_available_rounded,
            size: 40,
            color: AppColors.textSecondary.withValues(alpha: 0.45),
          ),
          const SizedBox(height: 12),
          Text(
            "No active reminder",
            style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Create one from your dashboard. When mode is Outdoor, you will get alerts here.",
            textAlign: TextAlign.center,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 14,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.reminder});

  final ReminderModel reminder;

  @override
  Widget build(BuildContext context) {
    final pending = isReminderPending(reminder.status);
    return Material(
      color: AppColors.slateCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: pending
                      ? AppColors.outdoorAccent.withValues(alpha: 0.12)
                      : AppColors.tealDeep.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  pending ? Icons.schedule_rounded : Icons.check_rounded,
                  color: pending ? AppColors.outdoorAccent : AppColors.tealDeep,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reminder.title.trim().isEmpty ? "Reminder" : reminder.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "${formatTimestampToLocal(reminder.timestamp)} · ${reminder.status}",
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionStatusCard extends StatelessWidget {
  const _ConnectionStatusCard({
    required this.backendUrl,
    required this.modeSource,
    required this.autoModeSetting,
    required this.bluetoothStatus,
    required this.rssi,
    required this.anchorName,
    required this.anchorId,
    required this.bluetoothReason,
  });

  final String backendUrl;
  final String modeSource;
  final String autoModeSetting;
  final String bluetoothStatus;
  final int? rssi;
  final String? anchorName;
  final String? anchorId;
  final String bluetoothReason;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.slateCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.tealDeep.withValues(alpha: 0.1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.dns_rounded, size: 20, color: AppColors.tealDeep),
              const SizedBox(width: 8),
              Text(
                "Connection",
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _miniRow("Server", backendUrl),
          _miniRow("Mode source", modeSource),
          _miniRow("Auto", autoModeSetting),
          _miniRow(
            "Bluetooth",
            "$bluetoothStatus · RSSI ${rssi != null ? "$rssi dBm" : "—"}",
          ),
          if (anchorName != null && anchorId != null)
            _miniRow("Linked PC", "$anchorName"),
          if (bluetoothReason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                bluetoothReason,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  color: AppColors.outdoorAccent,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _miniRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              k,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfigWarningCard extends StatelessWidget {
  const _ConfigWarningCard({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.errorContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.errorBorder.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFB91C1C)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Fix API address",
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFFB91C1C),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            "Current: $url\n\nUse a real LAN IP, e.g. "
            "--dart-define=API_BASE_URL=http://192.168.x.x:8000",
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13,
              height: 1.45,
              color: const Color(0xFF7F1D1D),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.cloud_off_rounded, color: Color(0xFFB91C1C)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                height: 1.4,
                color: const Color(0xFF7F1D1D),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
