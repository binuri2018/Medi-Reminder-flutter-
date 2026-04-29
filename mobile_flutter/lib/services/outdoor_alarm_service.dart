import "dart:async";
import "dart:convert";
import "dart:developer" as dev;
import "dart:ui";

import "package:android_alarm_manager_plus/android_alarm_manager_plus.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:flutter_local_notifications/flutter_local_notifications.dart";
import "package:flutter_tts/flutter_tts.dart";
import "package:http/http.dart" as http;
import "package:permission_handler/permission_handler.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:timezone/data/latest.dart" as tz;
import "package:timezone/timezone.dart" as tz;

import "../config/api_config.dart";
import "../models/reminder_model.dart";

const MethodChannel _kExactAlarmChannel =
    MethodChannel("com.example.mobile_flutter/exact_alarm");

// IMPORTANT: The channel id is versioned because Android caches the
// importance/sound/vibration settings of a channel forever after first
// creation. If the app previously registered an older variant of this channel
// (e.g. with a 0-byte sound file or before the WAV was bundled into the APK),
// mutating that channel later has no effect on devices where it already
// exists. Creating a brand new channel id forces Android to register the new
// sound + Importance.max settings.
//
// Whenever `_alarmChannelId` is bumped, also:
//   * append the previous id to `_legacyAlarmChannelIds` so we delete it on
//     init (keeps Settings -> Notifications tidy on upgrades).
//   * update backend/services/fcm_service.py -> data["channelId"] so FCM-side
//     hints match the local channel.
const String _alarmChannelId = "outdoor_alarm_channel_v3";
const String _alarmChannelName = "Outdoor alarm reminders";
const String _alarmChannelDescription =
    "Exact-time outdoor reminder alarms with vibration and custom sound";
const List<String> _legacyAlarmChannelIds = <String>[
  "outdoor_alarm_channel",
  "outdoor_alarm_channel_v2",
];

/// Tolerance for "fire immediately" path. If a reminder's dueTime is within
/// this window before now, we treat it as "now" and pop the notification
/// straight away. Anything older is considered stale and silently skipped so
/// past reminders do not all flood the user when they re-open the app.
///
/// Sized to absorb the worst-case end-to-end "fire now" latency without
/// dropping a real reminder:
///   * backend dispatcher loop interval (5s)
///   * FCM data push (primary) plus history/WorkManager backup
///   * clock skew and transport delay
///   * WorkManager safety-net interval (15min)
///   * a couple of human-scale buffer seconds
/// 5 minutes is the sweet spot: long enough for legitimate "fire now"
/// reminders to survive timing jitter, short enough that a multi-day-old
/// reminder still gets dropped instead of popping when the user opens the
/// app.
const Duration _pastDueTolerance = Duration(minutes: 5);
const String _scheduledRemindersPref = "scheduled_outdoor_reminders";
const String _reminderVoiceTextPref = "scheduled_outdoor_reminder_voice_text";
const String _reminderPayloadsPref = "scheduled_outdoor_reminder_payloads";
const String _pendingTapPref = "pending_outdoor_reminder_tap";
/// Set of reminder ids that the user already acknowledged locally
/// (notification "Done" button or in-app voice command). syncReminder /
/// syncReminderFromMessage / WorkManager all check this BEFORE firing so
/// the notification does not re-pop on the next 30s polling cycle just
/// because the backend ack POST is still in flight (or failed because the
/// network was flaky). Entries are pruned by `syncFromHistory` whenever
/// the backend confirms the reminder is no longer pending.
const String _locallyAckedRemindersPref =
    "locally_acknowledged_outdoor_reminders";
const String _doneActionId = "outdoor_reminder_done_action";

/// [alarmClock] requires SCHEDULE_EXACT_ALARM. Many devices never show that
/// special access until requested; without it both zonedSchedule attempts
/// used to fail and **no** notification was ever scheduled.
const List<AndroidScheduleMode> _androidZonedScheduleFallbacks =
    <AndroidScheduleMode>[
  AndroidScheduleMode.alarmClock,
  AndroidScheduleMode.exactAllowWhileIdle,
  AndroidScheduleMode.inexactAllowWhileIdle,
];

/// Fired by AndroidAlarmManager at the exact reminder time. Speaks the
/// reminder text via TTS even if the app is killed.
@pragma("vm:entry-point")
Future<void> outdoorVoiceAlarmCallback(
  int reminderIntId,
  Map<String, dynamic> params,
) async {
  // CRITICAL when running inside a background isolate (app killed):
  // without this call, plugin method-channels are not wired up and every
  // plugin call (FlutterTts, SharedPreferences, http, ...) silently fails.
  try {
    DartPluginRegistrant.ensureInitialized();
  } catch (_) {
    // intentional swallow: ensureInitialized is a no-op on subsequent
    // calls and may not be needed when running in the main isolate.
  }
  final reminderId = (params["reminderId"] ?? "").toString();
  final voiceText = (params["voiceText"] ?? "").toString();
  final firedAt = DateTime.now().toLocal();
  dev.log(
    "notification fired reminderId=$reminderId notifId=$reminderIntId "
    "immediate=false voiceAlarm=true at=$firedAt",
    name: "OutdoorAlarm",
  );
  if (kDebugMode) {
    debugPrint("alarm fired timestamp=$firedAt id=$reminderId notifId=$reminderIntId");
  }
  if (voiceText.isEmpty) {
    if (kDebugMode) {
      debugPrint("custom audio playback skipped: empty voice text");
    }
    return;
  }
  try {
    final tts = FlutterTts();
    await tts.setLanguage("en-US");
    await tts.setSpeechRate(0.48);
    await tts.setPitch(1.0);
    await tts.setVolume(1.0);
    if (kDebugMode) {
      debugPrint("custom audio playback started: id=$reminderId");
    }
    await tts.speak(voiceText);
  } catch (e) {
    if (kDebugMode) {
      debugPrint("custom audio playback failed and fallback used: $e");
    }
  }
}

/// Background isolate entry-point invoked by `flutter_local_notifications`
/// when the user interacts with the notification (e.g. taps the body or the
/// "Done" action) while the app is killed. Must be a top-level function.
///
/// Without [DartPluginRegistrant.ensureInitialized] this entry point sees
/// none of the app's plugins, so the Done button visibly dismisses the
/// notification (`cancelNotification: true` is OS-side) but the underlying
/// `acknowledgeAndCancel` work — SharedPreferences write, HTTP POST,
/// AlarmManager cancel — silently no-ops. That is exactly the symptom the
/// user reported as "the Done button doesn't work".
@pragma("vm:entry-point")
void outdoorNotificationBackgroundResponseHandler(NotificationResponse response) {
  try {
    DartPluginRegistrant.ensureInitialized();
  } catch (_) {
    // intentional swallow
  }
  // Run async work without awaiting since this entry point is sync.
  unawaited(
    OutdoorAlarmService.handleNotificationResponse(
      response,
      runningInBackground: true,
    ),
  );
}

class OutdoorAlarmService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  /// Streams reminder taps to the UI layer (HomeScreen). Set to a non-null
  /// reminder when the user opens the app from a reminder notification so the
  /// screen can scroll/show it and trigger TTS + vibration.
  static final ValueNotifier<ReminderModel?> pendingTapNotifier =
      ValueNotifier<ReminderModel?>(null);

  static bool _initialized = false;

  /// Per-isolate: FCM / WorkManager isolates must not run [initialize]'s
  /// channel wipe or launch-details path — that can cancel pending alarms
  /// or fail headlessly and leave notifications uninitialized.
  static bool _headlessNotificationsReady = false;

  /// Minimal plugin + channel setup for secondary isolates (FCM background,
  /// WorkManager). Does not delete notification channels or touch launch
  /// details.
  static Future<void> initializeForHeadlessDelivery() async {
    if (_headlessNotificationsReady) return;
    tz.initializeTimeZones();

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings("@mipmap/ic_launcher"),
    );
    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onForegroundNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          outdoorNotificationBackgroundResponseHandler,
    );

    const channel = AndroidNotificationChannel(
      _alarmChannelId,
      _alarmChannelName,
      description: _alarmChannelDescription,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      sound: RawResourceAndroidNotificationSound("reminder_alarm"),
    );
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    try {
      await androidPlugin?.createNotificationChannel(channel);
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          "headless alarm channel create with custom sound failed, fallback: $e",
        );
      }
      const fallbackChannel = AndroidNotificationChannel(
        _alarmChannelId,
        _alarmChannelName,
        description: _alarmChannelDescription,
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );
      await androidPlugin?.createNotificationChannel(fallbackChannel);
    }

    _headlessNotificationsReady = true;
  }

  static Future<void> initialize() async {
    if (_initialized) return;
    tz.initializeTimeZones();

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings("@mipmap/ic_launcher"),
    );
    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onForegroundNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          outdoorNotificationBackgroundResponseHandler,
    );

    const channel = AndroidNotificationChannel(
      _alarmChannelId,
      _alarmChannelName,
      description: _alarmChannelDescription,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      sound: RawResourceAndroidNotificationSound("reminder_alarm"),
    );
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    // Force-clean every legacy id AND the current id so we always recreate
    // the channel with the sound/importance/vibration settings from THIS
    // build of the app. Notification channel settings are immutable on
    // Android (createNotificationChannel is a no-op for an existing
    // channel id), so without an explicit delete here a previous install's
    // broken sound config would survive every reinstall.
    final idsToWipe = <String>{..._legacyAlarmChannelIds, _alarmChannelId};
    for (final id in idsToWipe) {
      try {
        await androidPlugin?.deleteNotificationChannel(id);
        if (kDebugMode) {
          debugPrint("alarm channel deleted (if existed): $id");
        }
      } catch (_) {
        // intentional swallow: deleteNotificationChannel is a no-op when the
        // channel never existed (fresh install).
      }
    }
    try {
      await androidPlugin?.createNotificationChannel(channel);
      if (kDebugMode) {
        debugPrint(
          "alarm channel ensured: id=$_alarmChannelId importance=max sound=res/raw/reminder_alarm",
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          "alarm channel create with custom sound failed, fallback to default: $e",
        );
      }
      // Fallback channel (no custom sound) so the popup, vibration and
      // importance still work even if `res/raw/reminder_alarm` is invalid
      // on this device.
      const fallbackChannel = AndroidNotificationChannel(
        _alarmChannelId,
        _alarmChannelName,
        description: _alarmChannelDescription,
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );
      await androidPlugin?.createNotificationChannel(fallbackChannel);
    }

    // Cold-start path: main isolate only. Must not break init if APIs misbehave
    // in a headless context (they should not run here).
    try {
      final launchDetails =
          await _notifications.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        final response = launchDetails!.notificationResponse;
        if (response != null) {
          await handleNotificationResponse(response, runningInBackground: false);
        }
      } else {
        await _restorePendingTapFromPrefs();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("notification launch details / tap restore skipped: $e");
      }
    }

    _initialized = true;
  }

  /// Opens the per-app "Alarms & reminders" screen (Android 12+). Uses
  /// [FLAG_ACTIVITY_NEW_TASK] from the Activity for OEMs where
  /// permission_handler's forResult path never lists the app.
  static Future<void> _openAndroidExactAlarmSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _kExactAlarmChannel.invokeMethod<void>("openExactAlarmSettings");
    } catch (e, st) {
      dev.log(
        "openExactAlarmSettings failed: $e",
        name: "OutdoorAlarm",
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Sends the user straight to this app's **Alarms & reminders** toggle
  /// (Android 12+). Use when Settings → Special app access is hard to find.
  /// No-op on non-Android. Reminders still work without this via inexact
  /// scheduling, but timing is less precise.
  static Future<void> openExactAlarmPermissionSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await Permission.scheduleExactAlarm.request();
    } catch (_) {}
    await _openAndroidExactAlarmSettings();
  }

  static Future<void> ensurePermissions() async {
    try {
      final notifStatus = await Permission.notification.request();
      if (kDebugMode) {
        debugPrint("alarm permission notification status: $notifStatus");
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("alarm permission notification request failed: $e");
      }
    }

    try {
      // SCHEDULE_EXACT_ALARM only (see AndroidManifest). permission_handler
      // uses startActivityForResult; some Samsung builds still omit the app
      // from "Alarms & reminders" until the package-scoped intent runs from
      // the Activity — see [_openAndroidExactAlarmSettings].
      var exactStatus = await Permission.scheduleExactAlarm.status;
      if (!exactStatus.isGranted) {
        exactStatus = await Permission.scheduleExactAlarm.request();
      }
      if (defaultTargetPlatform == TargetPlatform.android &&
          !exactStatus.isGranted) {
        await _openAndroidExactAlarmSettings();
      }
      exactStatus = await Permission.scheduleExactAlarm.status;
      if (kDebugMode) {
        debugPrint("alarm permission exact alarm status: $exactStatus");
      }
      if (!exactStatus.isGranted) {
        dev.log(
          "exact alarm not granted: use the system screen to allow this app, "
          "or Settings → Apps → Special app access → Alarms & reminders",
          name: "OutdoorAlarm",
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("alarm permission exact alarm request failed: $e");
      }
    }

    // Battery optimization exemption is what makes the difference between
    // "the popup fires at the exact reminder time even when the app is
    // killed" and "the popup only fires when I open the app". Without it,
    // Samsung/Xiaomi/Huawei OEMs put the app into Deep Sleep / Sleeping
    // Apps, which cancels WorkManager periodic work and even some exact
    // AlarmManager fires.
    //
    // We request once and remember the result. If the user denies, the
    // app still works while open; we just can't guarantee timely fires
    // when the app is killed. The user can grant it later from
    // Settings -> Apps -> Reminder -> Battery -> Unrestricted.
    try {
      final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
      if (kDebugMode) {
        debugPrint(
          "alarm permission battery-optimization current status: $batteryStatus",
        );
      }
      if (!batteryStatus.isGranted) {
        final requested =
            await Permission.ignoreBatteryOptimizations.request();
        if (kDebugMode) {
          debugPrint(
            "alarm permission battery-optimization requested: $requested",
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          "alarm permission battery-optimization request failed: $e "
          "(reminders may not fire when app is killed on aggressive OEMs)",
        );
      }
    }
  }

  /// Whether the latest reminder should trigger foreground handling now.
  ///
  /// Unlike [shouldPlayInAppVoice], this ignores the stale window so the app
  /// can still post a foreground notification for a due reminder even when the
  /// backend timestamp arrives late (clock skew / transport lag).
  static bool shouldAlertLatestInForeground(ReminderModel reminder) {
    if (reminder.id.isEmpty) return false;
    if (!isReminderPending(reminder.status)) return false;
    if (reminder.mode.trim().toLowerCase() != "outdoor") return false;
    final due = DateTime.tryParse(reminder.timestamp);
    if (due == null) return false;
    return !due.toUtc().isAfter(DateTime.now().toUtc());
  }

  /// Whether the reminder is in the same time window where [syncReminder]
  /// would fire the heads-up notification immediately (due now or within
  /// [_pastDueTolerance], not stale). HomeScreen uses this so in-app TTS
  /// does not run on every poll for far-future reminders — that was stealing
  /// audio focus and starving the 5s poll while [await _tts.speak] ran,
  /// which delayed registering the exact system notification.
  static bool shouldPlayInAppVoice(ReminderModel reminder) {
    if (reminder.id.isEmpty) return false;
    if (!isReminderPending(reminder.status)) return false;
    if (reminder.mode.trim().toLowerCase() != "outdoor") return false;
    final due = DateTime.tryParse(reminder.timestamp);
    if (due == null) return false;
    final dueUtc = due.toUtc();
    final nowUtc = DateTime.now().toUtc();
    final futureDelta = dueUtc.difference(nowUtc);
    if (futureDelta.isNegative && futureDelta.abs() > _pastDueTolerance) {
      return false;
    }
    return !dueUtc.isAfter(nowUtc);
  }

  /// Foreground fallback: if latest pending reminder is already due, post the
  /// notification right away even when history scheduling marked it stale.
  static Future<void> postForegroundDueNotification(ReminderModel reminder) async {
    if (!shouldAlertLatestInForeground(reminder)) return;
    final acked = await _loadLocallyAckedSet();
    if (acked.contains(reminder.id)) return;

    await initialize();
    final payload = jsonEncode(_reminderToMap(reminder));
    await _persistReminderPayload(reminder);
    await _showImmediateNotification(
      reminderId: reminder.id,
      reminderIntId: _idForReminder(reminder.id),
      title: _notificationTitleFor(reminder),
      body: _notificationBodyFor(
        reminder,
        dueLocal: DateTime.tryParse(reminder.timestamp)?.toLocal(),
      ),
      payload: payload,
    );
  }

  /// Schedules (or replaces) all alarms/notifications for `reminder`.
  /// Idempotent for a given `reminder.id` because every persistent ID is
  /// derived from the reminder ID and we dedupe on `(id, timestamp)` via
  /// SharedPreferences so polling/FCM/WorkManager cannot re-fire the same
  /// reminder repeatedly.
  static Future<void> syncReminder(
    ReminderModel reminder, {
    bool headlessNotificationSetup = false,
    bool allowStaleImmediate = false,
    // When true, skip posting our own local immediate-notification (the
    // OS-level FCM `notification` block already pops the notification on
    // background/killed states; doing it twice would create duplicates).
    // The voice/TTS callback and state persistence still run.
    bool suppressLocalNotification = false,
  }) async {
    if (headlessNotificationSetup) {
      await initializeForHeadlessDelivery();
    } else {
      await initialize();
    }
    // NOTE: ensurePermissions() is intentionally NOT called here. It used to
    // be, which caused an N-way race in package:permission_handler when
    // syncFromHistory processed multiple reminders in parallel - every call
    // raced the previous one and Android's PermissionManager rejected all of
    // them with "A request for permissions is already running...". The side
    // effect was that the battery-optimization request never completed,
    // which on Samsung/Xiaomi kills the WorkManager + AlarmManager safety
    // net and breaks the "fire at exact time when app is closed" guarantee.
    // Permissions are requested ONCE at startup from main.dart instead.

    if (kDebugMode) {
      debugPrint("syncReminder called: id=${reminder.id}");
    }

    if (reminder.id.isEmpty) {
      if (kDebugMode) {
        debugPrint("syncReminder skipped: reason=empty_reminderId");
      }
      return;
    }

    final due = DateTime.tryParse(reminder.timestamp);
    final nowLocal = DateTime.now().toLocal();
    final dueLocal = due?.toLocal();
    if (kDebugMode) {
      debugPrint(
        "syncReminder payload => id=${reminder.id} title=${reminder.title} "
        "message=${reminder.message} status=${reminder.status} mode=${reminder.mode} "
        "rawDueTime=${reminder.timestamp} parsedDueLocal=$dueLocal nowLocal=$nowLocal",
      );
    }
    if (due == null) {
      if (kDebugMode) {
        debugPrint(
          "syncReminder skipped: reason=invalid_dueTime raw=${reminder.timestamp}",
        );
      }
      return;
    }

    // Critical guard: never schedule/notify a reminder that is no longer
    // pending. Cancels anything already scheduled for that ID so a "done"
    // reminder cannot resurrect on this device.
    if (!isReminderPending(reminder.status)) {
      if (kDebugMode) {
        debugPrint(
          "syncReminder skipped: reason=non_pending_status status=${reminder.status} id=${reminder.id}",
        );
      }
      await cancelReminder(reminder.id);
      return;
    }

    // Critical guard: never schedule indoor reminders on the phone.
    if (reminder.mode.trim().toLowerCase() != "outdoor") {
      if (kDebugMode) {
        debugPrint(
          "syncReminder skipped: reason=non_outdoor_mode mode=${reminder.mode} id=${reminder.id}",
        );
      }
      await cancelReminder(reminder.id);
      return;
    }

    // Local-ack guard: the user already pressed "Done" (or said "done")
    // for this reminder id. The backend may still report it as pending
    // (network glitch, ack POST not yet processed) but the user's intent
    // is unambiguous - never re-pop the notification on the next polling
    // cycle. Entries are cleared by syncFromHistory when the backend
    // confirms the reminder is no longer pending.
    final ackedSet = await _loadLocallyAckedSet();
    if (ackedSet.contains(reminder.id)) {
      if (kDebugMode) {
        debugPrint(
          "syncReminder skipped: reason=locally_acknowledged id=${reminder.id}",
        );
      }
      return;
    }

    // Idempotency guard: if we already scheduled / fired this same
    // reminder id, don't do it again. Polling and history-sync would
    // otherwise re-fire past reminders on every cycle.
    //
    // We treat as "already handled" if EITHER the (id, exact-timestamp)
    // is matched OR the stored timestamp is within 30s of the incoming
    // timestamp. The 30s jitter window absorbs the case where the
    // backend's history endpoint returns slightly different dueTime
    // strings for the same logical reminder across polls (we have
    // observed this in production logs: same id, dueTime values that
    // differ by minutes from cycle to cycle). Genuine reschedules
    // (snooze/edit) move the dueTime by far more than 30s and still
    // bypass this short-circuit.
    final scheduledMap = await _loadScheduledMap();
    final storedTimestamp = scheduledMap[reminder.id];
    bool alreadyHandled = storedTimestamp == reminder.timestamp;
    if (!alreadyHandled && storedTimestamp != null) {
      final storedDue = DateTime.tryParse(storedTimestamp);
      final incomingDue = DateTime.tryParse(reminder.timestamp);
      if (storedDue != null && incomingDue != null) {
        final jitter = storedDue.difference(incomingDue).abs();
        if (jitter <= const Duration(seconds: 30)) {
          alreadyHandled = true;
        }
      }
    }
    if (alreadyHandled) {
      if (kDebugMode) {
        debugPrint(
          "syncReminder skipped: reason=already_handled id=${reminder.id} "
          "incomingDueTime=${reminder.timestamp} storedDueTime=$storedTimestamp",
        );
      }
      return;
    }

    final reminderIntId = _idForReminder(reminder.id);
    final voiceText = _selectVoiceText(reminder);
    final voiceMap = await _loadVoiceMap();
    final previousVoiceText = voiceMap[reminder.id];
    if (previousVoiceText != voiceText) {
      voiceMap[reminder.id] = voiceText;
      await _saveVoiceMap(voiceMap);
      if (kDebugMode) {
        debugPrint("custom audio generated/cached: id=${reminder.id}");
      }
    } else if (kDebugMode) {
      debugPrint("custom audio cache reused: id=${reminder.id}");
    }
    if (kDebugMode) {
      debugPrint("reminder text selected for voice: $voiceText");
    }

    final payload = jsonEncode(_reminderToMap(reminder));
    await _persistReminderPayload(reminder);

    final notifTitle = _notificationTitleFor(reminder);
    final notifBody = _notificationBodyFor(reminder, dueLocal: dueLocal);

    final nowUtc = DateTime.now().toUtc();
    final dueUtc = due.toUtc();

    // Three-way decision tree, intentionally NOT collapsing past-due into a
    // single "fire immediately" branch. Re-opening the app after any reminder
    // missed its time used to flood the user with stale notifications because
    // syncFromHistory would re-call us for every pending+outdoor reminder.
    final futureDelta = dueUtc.difference(nowUtc);
    if (futureDelta.isNegative &&
        futureDelta.abs() > _pastDueTolerance) {
      if (allowStaleImmediate) {
        if (kDebugMode) {
          debugPrint(
            "syncReminder stale override -> fire immediate: id=${reminder.id} "
            "ageSec=${futureDelta.abs().inSeconds} tolerance=${_pastDueTolerance.inSeconds}s "
            "suppressLocalNotification=$suppressLocalNotification",
          );
        }
        if (!suppressLocalNotification) {
          await _showImmediateNotification(
            reminderId: reminder.id,
            reminderIntId: reminderIntId,
            title: notifTitle,
            body: notifBody,
            payload: payload,
          );
        }
        try {
          unawaited(
            outdoorVoiceAlarmCallback(
              _voiceAlarmIdForReminder(reminder.id),
              <String, dynamic>{
                "reminderId": reminder.id,
                "voiceText": voiceText,
              },
            ),
          );
        } catch (_) {}
        await _markScheduled(reminder.id, reminder.timestamp);
        return;
      }
      // Stale (more than _pastDueTolerance in the past). Do NOT pop a
      // notification on app open / poll cycle - the user already missed the
      // event, and they can find it in history. We still mark it as handled
      // so subsequent syncs don't reconsider it.
      if (kDebugMode) {
        debugPrint(
          "syncReminder skipped: reason=stale_past_due id=${reminder.id} "
          "ageSec=${futureDelta.abs().inSeconds} tolerance=${_pastDueTolerance.inSeconds}s "
          "dueLocal=${dueUtc.toLocal()} nowLocal=${nowUtc.toLocal()}",
        );
      }
      // Cancel any orphan local alarm and remember we've seen it so we do
      // not reconsider it on every poll.
      await cancelReminder(reminder.id);
      await _markScheduled(reminder.id, reminder.timestamp);
      return;
    }

    final fireImmediately = !dueUtc.isAfter(nowUtc);
    if (fireImmediately) {
      // Recent past (within tolerance). Server pushed for "now" or polling
      // raced the dispatch by a few hundred ms. Pop the notification now.
      if (kDebugMode) {
        debugPrint(
          "syncReminder firing immediately: id=${reminder.id} "
          "dueLocal=${dueUtc.toLocal()} nowLocal=${nowUtc.toLocal()} "
          "pastSec=${futureDelta.abs().inSeconds} "
          "suppressLocalNotification=$suppressLocalNotification",
        );
      }
      if (!suppressLocalNotification) {
        await _showImmediateNotification(
          reminderId: reminder.id,
          reminderIntId: reminderIntId,
          title: notifTitle,
          body: notifBody,
          payload: payload,
        );
      }
      try {
        unawaited(
          outdoorVoiceAlarmCallback(
            _voiceAlarmIdForReminder(reminder.id),
            <String, dynamic>{
              "reminderId": reminder.id,
              "voiceText": voiceText,
            },
          ),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint("immediate voice playback failed: $e");
        }
      }
    } else {
      // Truly future. Schedule a zoned notification + an exact AlarmManager
      // entry for the voice/TTS playback.
      if (kDebugMode) {
        debugPrint(
          "syncReminder scheduling future: id=${reminder.id} "
          "dueLocal=${dueUtc.toLocal()} nowLocal=${nowUtc.toLocal()} "
          "inSec=${futureDelta.inSeconds}",
        );
      }
      await _scheduleZonedNotification(
        reminderId: reminder.id,
        reminderIntId: reminderIntId,
        title: notifTitle,
        body: notifBody,
        dueUtc: dueUtc,
        payload: payload,
      );

      try {
        // AndroidAlarmManager.initialize must be called once per isolate
        // before scheduling. The main isolate calls it from main.dart,
        // but the WorkManager safety-net runs in its own isolate that has
        // never seen initialize(). The plugin's initialize is idempotent
        // so the cost in the main isolate is just a method-channel
        // round-trip.
        await AndroidAlarmManager.initialize();
        final voiceId = _voiceAlarmIdForReminder(reminder.id);
        final voiceParams = <String, dynamic>{
          "reminderId": reminder.id,
          "voiceText": voiceText,
        };
        var voiceOk = await AndroidAlarmManager.oneShotAt(
          dueUtc.toLocal(),
          voiceId,
          outdoorVoiceAlarmCallback,
          exact: true,
          wakeup: true,
          allowWhileIdle: true,
          rescheduleOnReboot: true,
          params: voiceParams,
        );
        if (voiceOk != true) {
          voiceOk = await AndroidAlarmManager.oneShotAt(
            dueUtc.toLocal(),
            voiceId,
            outdoorVoiceAlarmCallback,
            exact: false,
            wakeup: true,
            allowWhileIdle: true,
            rescheduleOnReboot: true,
            params: voiceParams,
          );
        }
        if (kDebugMode && voiceOk != true) {
          debugPrint(
            "AndroidAlarmManager.oneShotAt inexact fallback also failed id=${reminder.id}",
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint("AndroidAlarmManager.oneShotAt failed: $e");
        }
        try {
          await AndroidAlarmManager.initialize();
          await AndroidAlarmManager.oneShotAt(
            dueUtc.toLocal(),
            _voiceAlarmIdForReminder(reminder.id),
            outdoorVoiceAlarmCallback,
            exact: false,
            wakeup: true,
            allowWhileIdle: true,
            rescheduleOnReboot: true,
            params: {
              "reminderId": reminder.id,
              "voiceText": voiceText,
            },
          );
        } catch (_) {
          // Voice alarm is optional if notification still fires.
        }
      }
    }

    await _markScheduled(reminder.id, reminder.timestamp);
    if (kDebugMode) {
      debugPrint(
        "notification scheduled successfully: id=${reminder.id} "
        "dueLocal=${dueUtc.toLocal()} notifId=$reminderIntId immediate=$fireImmediately",
      );
    }
  }

  static Future<void> _scheduleZonedNotification({
    required String reminderId,
    required int reminderIntId,
    required String title,
    required String body,
    required DateTime dueUtc,
    required String payload,
  }) async {
    if (kDebugMode) {
      debugPrint(
        "_scheduleZonedNotification posting: notifId=$reminderIntId "
        "title='$title' body='$body' dueLocal=${dueUtc.toLocal()}",
      );
    }
    final scheduled = tz.TZDateTime.from(dueUtc, tz.UTC);
    for (final withCustomSound in <bool>[true, false]) {
      final details = _buildNotificationDetails(
        withCustomSound: withCustomSound,
      );
      for (final mode in _androidZonedScheduleFallbacks) {
        try {
          await _notifications.zonedSchedule(
            reminderIntId,
            title,
            body,
            scheduled,
            details,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            androidScheduleMode: mode,
            payload: payload,
          );
          dev.log(
            "local alarm scheduled reminderId=$reminderId dueUtc=$dueUtc "
            "notifId=$reminderIntId withCustomSound=$withCustomSound mode=$mode",
            name: "OutdoorAlarm",
          );
          if (kDebugMode) {
            debugPrint(
              "_scheduleZonedNotification ok: notifId=$reminderIntId "
              "sound=$withCustomSound mode=$mode",
            );
          }
          return;
        } catch (e, st) {
          dev.log(
            "zonedSchedule failed sound=$withCustomSound mode=$mode: $e",
            name: "OutdoorAlarm",
            error: e,
            stackTrace: st,
          );
          if (kDebugMode) {
            debugPrint(
              "zonedSchedule failed notifId=$reminderIntId sound=$withCustomSound "
              "mode=$mode err=$e",
            );
          }
        }
      }
    }
    if (kDebugMode) {
      debugPrint(
        "_scheduleZonedNotification exhausted all modes: notifId=$reminderIntId",
      );
    }
  }

  static Future<void> _showImmediateNotification({
    required String reminderId,
    required int reminderIntId,
    required String title,
    required String body,
    required String payload,
  }) async {
    if (kDebugMode) {
      debugPrint(
        "_showImmediateNotification posting: notifId=$reminderIntId title='$title' body='$body'",
      );
    }
    Future<bool> tryShow({
      required bool withCustomSound,
      required bool useFullScreenIntent,
    }) async {
      try {
        await _notifications.show(
          reminderIntId,
          title,
          body,
          _buildNotificationDetails(
            withCustomSound: withCustomSound,
            useFullScreenIntent: useFullScreenIntent,
          ),
          payload: payload,
        );
        dev.log(
          "notification fired reminderId=$reminderId notifId=$reminderIntId "
          "immediate=true withCustomSound=$withCustomSound fullScreen=$useFullScreenIntent",
          name: "OutdoorAlarm",
        );
        if (kDebugMode) {
          debugPrint(
            "_showImmediateNotification posted: notifId=$reminderIntId "
            "sound=$withCustomSound fullScreen=$useFullScreenIntent",
          );
        }
        return true;
      } catch (e, st) {
        dev.log(
          "immediate show failed sound=$withCustomSound fullScreen=$useFullScreenIntent: $e",
          name: "OutdoorAlarm",
          error: e,
          stackTrace: st,
        );
        if (kDebugMode) {
          debugPrint("_showImmediateNotification try failed: $e");
        }
        return false;
      }
    }

    if (await tryShow(withCustomSound: true, useFullScreenIntent: true)) {
      return;
    }
    if (await tryShow(withCustomSound: true, useFullScreenIntent: false)) {
      return;
    }
    if (await tryShow(withCustomSound: false, useFullScreenIntent: true)) {
      return;
    }
    await tryShow(withCustomSound: false, useFullScreenIntent: false);
  }

  static NotificationDetails _buildNotificationDetails({
    required bool withCustomSound,
    bool useFullScreenIntent = true,
  }) {
    final actions = <AndroidNotificationAction>[
      const AndroidNotificationAction(
        _doneActionId,
        "Done",
        showsUserInterface: false,
        cancelNotification: true,
      ),
    ];
    final android = AndroidNotificationDetails(
      _alarmChannelId,
      _alarmChannelName,
      channelDescription: _alarmChannelDescription,
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      enableVibration: true,
      sound: withCustomSound
          ? const RawResourceAndroidNotificationSound("reminder_alarm")
          : null,
      category: AndroidNotificationCategory.alarm,
      ticker: "Outdoor alarm fired",
      // Lock-screen visible heads-up. On Android 14+ full-screen may be
      // downgraded or rejected for some apps; retries use false so the
      // notification still posts.
      fullScreenIntent: useFullScreenIntent,
      visibility: NotificationVisibility.public,
      // Vibration pattern (ms): wait, vibrate, wait, vibrate, ...
      // Must be set at post time too because some OEMs ignore the
      // channel-level vibration when the channel was created without
      // `vibrationPattern`.
      vibrationPattern: Int64List.fromList(<int>[0, 350, 200, 350, 200, 450]),
      actions: actions,
    );
    return NotificationDetails(android: android);
  }

  static String _notificationTitleFor(ReminderModel reminder) {
    return "Reminder: ${_displayTitle(reminder)}";
  }

  static String _notificationBodyFor(
    ReminderModel reminder, {
    DateTime? dueLocal,
  }) {
    final body = _displayBody(reminder);
    if (dueLocal == null) return body;
    final hh = dueLocal.hour.toString().padLeft(2, "0");
    final mm = dueLocal.minute.toString().padLeft(2, "0");
    return "$body  ($hh:$mm)";
  }

  /// Reconciles all currently scheduled local alarms with the backend
  /// history list. Anything pending+outdoor gets (re)scheduled, everything
  /// else (acknowledged/done/indoor/missing) gets cancelled so a stale
  /// alarm cannot survive on the device.
  static Future<void> syncFromHistory(
    List<ReminderModel> reminders, {
    bool headlessWorker = false,
  }) async {
    if (headlessWorker) {
      await initializeForHeadlessDelivery();
    } else {
      await initialize();
    }

    // Dedupe input by id, keeping the entry with the latest timestamp.
    // The backend's /api/reminders/history endpoint can return multiple
    // rows for the same logical reminder id (each dispatch attempt or
    // edit creates a new row). Without this, every polling cycle would
    // re-process the same id N times, hammering the SharedPreferences
    // and re-running cancelReminder/syncReminder for each duplicate.
    final dedupedById = <String, ReminderModel>{};
    for (final reminder in reminders) {
      if (reminder.id.isEmpty) continue;
      final existing = dedupedById[reminder.id];
      if (existing == null) {
        dedupedById[reminder.id] = reminder;
      } else {
        // Keep the entry with the larger (lexicographically last) ISO-8601
        // timestamp string. This works because ISO-8601 is sortable as a
        // string when timezone-aligned; both entries come from the same
        // backend so this is reliable in practice.
        if (reminder.timestamp.compareTo(existing.timestamp) > 0) {
          dedupedById[reminder.id] = reminder;
        }
      }
    }

    final seenIds = <String>{};
    final pendingIds = <String>{};
    final ackedSet = await _loadLocallyAckedSet();
    final ackedToPrune = <String>{};
    int firedImmediately = 0;
    int scheduledFuture = 0;
    int staleSkipped = 0;
    int nonPendingCancelled = 0;
    int nonOutdoorCancelled = 0;
    int locallyAckedSkipped = 0;
    int alreadyHandledSkipped = 0;

    for (final reminder in dedupedById.values) {
      seenIds.add(reminder.id);
      final mode = reminder.mode.trim().toLowerCase();
      if (mode == "outdoor" && isReminderPending(reminder.status)) {
        pendingIds.add(reminder.id);
        // Pre-classify so the summary log is meaningful even when
        // syncReminder short-circuits internally.
        if (ackedSet.contains(reminder.id)) {
          locallyAckedSkipped += 1;
        } else {
          final scheduledMap = await _loadScheduledMap();
          if (scheduledMap[reminder.id] == reminder.timestamp) {
            alreadyHandledSkipped += 1;
          }
          final due = DateTime.tryParse(reminder.timestamp);
          if (due != null) {
            final delta = due.toUtc().difference(DateTime.now().toUtc());
            if (delta.isNegative && delta.abs() > _pastDueTolerance) {
              staleSkipped += 1;
            } else if (delta.isNegative || delta == Duration.zero) {
              firedImmediately += 1;
            } else {
              scheduledFuture += 1;
            }
          }
        }
        await syncReminder(
          reminder,
          headlessNotificationSetup: headlessWorker,
        );
      } else if (mode != "outdoor") {
        nonOutdoorCancelled += 1;
        await cancelReminder(reminder.id);
        if (ackedSet.contains(reminder.id)) {
          ackedToPrune.add(reminder.id);
        }
      } else {
        // Outdoor but non-pending: backend confirms it's done/acked.
        nonPendingCancelled += 1;
        await cancelReminder(reminder.id);
        if (ackedSet.contains(reminder.id)) {
          ackedToPrune.add(reminder.id);
        }
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final existingMap = _decodeMap(prefs.getString(_scheduledRemindersPref));
    for (final existingId in existingMap.keys) {
      if (!seenIds.contains(existingId)) {
        await cancelReminder(existingId);
        if (ackedSet.contains(existingId)) {
          ackedToPrune.add(existingId);
        }
      }
    }
    // Prune the local-ack set for ids the backend has confirmed are no
    // longer pending. This keeps the set small over time and ensures we
    // never permanently mute reminder ids.
    final ackedToReallyPrune = ackedToPrune.difference(pendingIds);
    if (ackedToReallyPrune.isNotEmpty) {
      await _removeLocallyAcked(ackedToReallyPrune);
    }

    if (kDebugMode) {
      debugPrint(
        "syncFromHistory summary: rawCount=${reminders.length} "
        "uniqueIds=${dedupedById.length} "
        "scheduledFuture=$scheduledFuture firedImmediately=$firedImmediately "
        "staleSkipped=$staleSkipped alreadyHandled=$alreadyHandledSkipped "
        "locallyAcked=$locallyAckedSkipped "
        "nonPendingCancelled=$nonPendingCancelled "
        "nonOutdoorCancelled=$nonOutdoorCancelled "
        "tolerance=${_pastDueTolerance.inSeconds}s",
      );
    }
  }

  static Future<void> cancelReminder(String reminderId) async {
    if (reminderId.isEmpty) return;
    // Avoid recursive calls into initialize() from background isolates.
    final reminderIntId = _idForReminder(reminderId);
    try {
      await _notifications.cancel(reminderIntId);
    } catch (e) {
      if (kDebugMode) {
        debugPrint("cancel notification failed: $e");
      }
    }
    try {
      // AndroidAlarmManager.cancel needs initialize to have been called in
      // this isolate. Idempotent, so cheap in the main isolate. Critical
      // when called from the background isolate (e.g. Done action handler
      // running while the app is killed).
      await AndroidAlarmManager.initialize();
      await AndroidAlarmManager.cancel(_voiceAlarmIdForReminder(reminderId));
    } catch (e) {
      if (kDebugMode) {
        debugPrint("cancel AndroidAlarmManager failed: $e");
      }
    }
    await _removeScheduled(reminderId);
    final voiceMap = await _loadVoiceMap();
    voiceMap.remove(reminderId);
    await _saveVoiceMap(voiceMap);
    final payloadMap = await _loadPayloadMap();
    payloadMap.remove(reminderId);
    await _savePayloadMap(payloadMap);
    if (kDebugMode) {
      debugPrint("alarm cancelled: id=$reminderId notifId=$reminderIntId");
    }
  }

  /// Acknowledges via the backend and tears down all local scheduling.
  /// Used by the "Done" notification action and the in-app voice command.
  /// Safe to call from background isolates.
  ///
  /// Order of operations is deliberate:
  ///   1. Record the local ack in SharedPreferences. This is the *most
  ///      important* step - it stops the next polling cycle from re-popping
  ///      the same notification in the ~30s window before the backend
  ///      confirms the ack.
  ///   2. Cancel the system notification immediately (instant UX).
  ///   3. Cancel the AlarmManager voice fire and clean local prefs.
  ///   4. POST to the backend ack endpoint. We always await this with a
  ///      short timeout so the background isolate spawned for the action
  ///      stays alive long enough for the request to actually be sent on
  ///      the wire (Android may kill the receiver process after ~10s).
  static Future<void> acknowledgeAndCancel(
    String reminderId, {
    String acknowledgedBy = "android_phone",
  }) async {
    if (reminderId.isEmpty) return;
    if (kDebugMode) {
      debugPrint(
        "acknowledgeAndCancel start: id=$reminderId by=$acknowledgedBy",
      );
    }

    // 1. Record local ack first so polling cannot re-pop the notification
    //    even if every later step fails.
    await _addLocallyAcked(reminderId);

    // 2. Dismiss the system notification immediately. Tap-on-action with
    //    `cancelNotification: true` should already have dismissed it, but
    //    on some OEMs the heads-up survives - belt and braces.
    try {
      await _notifications.cancel(_idForReminder(reminderId));
      if (kDebugMode) {
        debugPrint("acknowledgeAndCancel notification cancelled: id=$reminderId");
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("acknowledgeAndCancel notification cancel failed: $e");
      }
    }

    // 3. Tear down the voice/AlarmManager piece. AndroidAlarmManager
    //    initialize is idempotent and is required when running inside a
    //    freshly spawned background isolate (Done tap on a killed app).
    try {
      await AndroidAlarmManager.initialize();
    } catch (_) {}
    await cancelReminder(reminderId);
    await _clearPendingTap();

    // 4. POST the ack. We *await* this so the background isolate stays
    //    alive long enough for the request to actually go out, but we cap
    //    the timeout aggressively so the UX cost in the foreground path
    //    is bounded.
    await _postAckBestEffort(reminderId, acknowledgedBy);
    if (kDebugMode) {
      debugPrint(
        "acknowledgeAndCancel complete: id=$reminderId",
      );
    }
  }

  /// POSTs the ack to the backend. Retries on transient failure so the Done
  /// button reliably propagates to the server even when the network is slow
  /// or the background isolate is racing the OS for time.
  ///
  /// Why retry:
  ///   * The Done action runs in a background isolate when the app is
  ///     killed. Android may delay the network stack briefly, especially on
  ///     Doze wake-up, so the first POST sometimes times out.
  ///   * Without a retry, a missed ack means the next polling cycle re-pops
  ///     the same notification (the local-ack guard masks this client-side
  ///     but the backend still shows the reminder as pending forever).
  static Future<void> _postAckBestEffort(
    String reminderId,
    String acknowledgedBy,
  ) async {
    final uri = Uri.parse(
      "${ApiConfig.baseUrl}/api/reminders/$reminderId/ack",
    );
    final body = jsonEncode({"acknowledged_by": acknowledgedBy});
    const headers = {"Content-Type": "application/json"};
    const maxAttempts = 3;
    const perAttemptTimeout = Duration(seconds: 8);
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await http
            .post(uri, headers: headers, body: body)
            .timeout(perAttemptTimeout);
        if (kDebugMode) {
          debugPrint(
            "ack POST result: id=$reminderId attempt=$attempt status=${response.statusCode}",
          );
        }
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return;
        }
        // Non-2xx: only retry on 5xx and 408. Anything else is a bug we
        // can't fix by retrying.
        if (response.statusCode != 408 && response.statusCode < 500) {
          return;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            "ack POST attempt $attempt failed: id=$reminderId err=$e",
          );
        }
      }
      if (attempt < maxAttempts) {
        // Linear backoff so we keep the background isolate alive for a
        // bounded amount of time. The OS gives us roughly 30s before it
        // reaps the receiver process.
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
    if (kDebugMode) {
      debugPrint(
        "ack POST gave up after $maxAttempts attempts: id=$reminderId "
        "(local cancel/ack already applied; next history sync will reconcile)",
      );
    }
  }

  // -------------------------------------------------------------------------
  // Tap-to-navigate plumbing
  // -------------------------------------------------------------------------

  static Future<void> _onForegroundNotificationResponse(
    NotificationResponse response,
  ) async {
    await handleNotificationResponse(response, runningInBackground: false);
  }

  /// Resolves the reminder associated with [response]. Prefer the serialized
  /// payload; some OEM skins strip extras on notification-action taps — in
  /// that case we recover using [NotificationResponse.id] (the Android posting
  /// id equals [_idForReminder]) and [_loadPayloadMap].
  static Future<ReminderModel?> _reminderFromNotificationResponse(
    NotificationResponse response,
  ) async {
    final direct = _decodeReminderPayload(response.payload);
    if (direct != null && direct.id.isNotEmpty) return direct;

    final nid = response.id;
    if (nid == null) return null;
    try {
      final map = await _loadPayloadMap();
      for (final entry in map.entries) {
        if (_idForReminder(entry.key) == nid) {
          final r = _decodeReminderPayload(entry.value);
          if (r != null && r.id.isNotEmpty) return r;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Top-level entrypoint for both isolates. Routing logic lives here so
  /// the foreground and background paths behave identically.
  static Future<void> handleNotificationResponse(
    NotificationResponse response, {
    required bool runningInBackground,
  }) async {
    final reminder = await _reminderFromNotificationResponse(response);
    if (kDebugMode) {
      debugPrint(
        "notification tap callback fired: actionId=${response.actionId} "
        "background=$runningInBackground payloadDecoded=${reminder != null} "
        "reminderId=${reminder?.id} title=${reminder?.title}",
      );
    }
    if (reminder == null || reminder.id.isEmpty) {
      if (kDebugMode) {
        debugPrint("notification tap ignored: payload missing reminder id");
      }
      return;
    }

    if (response.actionId == _doneActionId) {
      if (kDebugMode) {
        debugPrint(
          "Done action callback fired: id=${reminder.id} background=$runningInBackground",
        );
      }
      await acknowledgeAndCancel(
        reminder.id,
        acknowledgedBy: "android_phone_notification_action",
      );
      return;
    }

    // Body tap: persist for cold-start recovery and notify the live UI.
    await _persistPendingTap(reminder);
    if (kDebugMode) {
      debugPrint(
        "navigation triggered for reminder tap: id=${reminder.id} "
        "background=$runningInBackground",
      );
    }
    if (!runningInBackground) {
      pendingTapNotifier.value = reminder;
    }
  }

  /// Called by HomeScreen once it has surfaced the reminder, so we don't
  /// re-trigger TTS/vibration on next rebuild or app resume.
  static Future<void> consumePendingTap() async {
    pendingTapNotifier.value = null;
    await _clearPendingTap();
  }

  static Future<void> _persistPendingTap(ReminderModel reminder) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _pendingTapPref,
        jsonEncode(_reminderToMap(reminder)),
      );
    } catch (_) {
      // shared prefs unavailable in tests; the notifier still works
    }
  }

  static Future<void> _clearPendingTap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingTapPref);
    } catch (_) {
      // intentional swallow
    }
  }

  static Future<void> _restorePendingTapFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingTapPref);
      if (raw == null || raw.isEmpty) return;
      final reminder = _decodeReminderPayload(raw);
      if (reminder != null) {
        pendingTapNotifier.value = reminder;
      }
    } catch (_) {
      // intentional swallow
    }
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  static int _idForReminder(String reminderId) =>
      reminderId.hashCode & 0x7fffffff;
  static int _voiceAlarmIdForReminder(String reminderId) =>
      ((reminderId.hashCode & 0x7fffffff) % 100000000) + 100000000;

  static String _displayTitle(ReminderModel reminder) {
    final t = reminder.title.trim();
    if (t.isNotEmpty) return t;
    final m = reminder.message.trim();
    if (m.isNotEmpty) return m;
    return "Outdoor reminder";
  }

  static String _displayBody(ReminderModel reminder) {
    final m = reminder.message.trim();
    if (m.isNotEmpty) return m;
    final t = reminder.title.trim();
    if (t.isNotEmpty) return t;
    return "Please check your reminder now.";
  }

  static String _selectVoiceText(ReminderModel reminder) {
    final message = _cleanupVoiceText(reminder.message);
    final title = _cleanupVoiceText(reminder.title);
    if (message.isNotEmpty) return message;
    if (title.isNotEmpty) return title;
    return "Reminder alert. Please check your reminder.";
  }

  static String _cleanupVoiceText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return "";
    return trimmed.replaceAll(RegExp(r"\s+"), " ");
  }

  static Map<String, dynamic> _reminderToMap(ReminderModel reminder) {
    return {
      "reminderId": reminder.id,
      "title": reminder.title,
      "message": reminder.message,
      "dueTime": reminder.timestamp,
      "mode": reminder.mode,
      "status": reminder.status,
    };
  }

  static ReminderModel? _decodeReminderPayload(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      // Tolerate both the alarm-payload shape (`reminderId`/`dueTime`) and the
      // backend shape (`id`/`timestamp`) so the same helper can decode either.
      final id = (decoded["reminderId"] ?? decoded["id"] ?? "").toString();
      final timestamp =
          (decoded["dueTime"] ?? decoded["timestamp"] ?? "").toString();
      return ReminderModel(
        id: id,
        title: (decoded["title"] ?? "").toString(),
        message: (decoded["message"] ?? "").toString(),
        timestamp: timestamp,
        mode: (decoded["mode"] ?? "outdoor").toString(),
        status: (decoded["status"] ?? "pending").toString(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _persistReminderPayload(ReminderModel reminder) async {
    try {
      final map = await _loadPayloadMap();
      map[reminder.id] = jsonEncode(_reminderToMap(reminder));
      await _savePayloadMap(map);
    } catch (_) {
      // intentional swallow
    }
  }

  static Future<Map<String, String>> _loadScheduledMap() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeMap(prefs.getString(_scheduledRemindersPref));
  }

  static Future<Set<String>> _loadLocallyAckedSet() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_locallyAckedRemindersPref);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded.map((e) => e.toString()).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _addLocallyAcked(String reminderId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadLocallyAckedSet();
    if (!current.add(reminderId)) return; // already present
    await prefs.setString(
      _locallyAckedRemindersPref,
      jsonEncode(current.toList()),
    );
    if (kDebugMode) {
      debugPrint("local-ack set updated (added): id=$reminderId");
    }
  }

  static Future<void> _removeLocallyAcked(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadLocallyAckedSet();
    final before = current.length;
    current.removeAll(ids);
    if (current.length == before) return;
    await prefs.setString(
      _locallyAckedRemindersPref,
      jsonEncode(current.toList()),
    );
    if (kDebugMode) {
      debugPrint("local-ack set updated (pruned): pruned=${before - current.length}");
    }
  }

  static Future<void> _markScheduled(String reminderId, String dueTime) async {
    final prefs = await SharedPreferences.getInstance();
    final map = _decodeMap(prefs.getString(_scheduledRemindersPref));
    map[reminderId] = dueTime;
    await prefs.setString(_scheduledRemindersPref, jsonEncode(map));
  }

  static Future<void> _removeScheduled(String reminderId) async {
    final prefs = await SharedPreferences.getInstance();
    final map = _decodeMap(prefs.getString(_scheduledRemindersPref));
    map.remove(reminderId);
    await prefs.setString(_scheduledRemindersPref, jsonEncode(map));
  }

  static Future<Map<String, String>> _loadVoiceMap() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeMap(prefs.getString(_reminderVoiceTextPref));
  }

  static Future<void> _saveVoiceMap(Map<String, String> value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_reminderVoiceTextPref, jsonEncode(value));
  }

  static Future<Map<String, String>> _loadPayloadMap() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeMap(prefs.getString(_reminderPayloadsPref));
  }

  static Future<void> _savePayloadMap(Map<String, String> value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_reminderPayloadsPref, jsonEncode(value));
  }

  static Map<String, String> _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <String, String>{};
      return decoded.map(
        (k, v) => MapEntry(k, v?.toString() ?? ""),
      );
    } catch (_) {
      return <String, String>{};
    }
  }
}
