import "dart:convert";

import "package:android_alarm_manager_plus/android_alarm_manager_plus.dart";
import "package:flutter/foundation.dart";
import "package:flutter_local_notifications/flutter_local_notifications.dart";
import "package:flutter_tts/flutter_tts.dart";
import "package:permission_handler/permission_handler.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:timezone/data/latest.dart" as tz;
import "package:timezone/timezone.dart" as tz;

import "../models/reminder_model.dart";

const String _alarmChannelId = "outdoor_alarm_channel";
const String _alarmChannelName = "Outdoor alarm reminders";
const String _alarmChannelDescription =
    "Exact-time outdoor reminder alarms with vibration and custom sound";
const String _scheduledRemindersPref = "scheduled_outdoor_reminders";
const String _reminderVoiceTextPref = "scheduled_outdoor_reminder_voice_text";

@pragma("vm:entry-point")
Future<void> outdoorVoiceAlarmCallback(int reminderIntId, Map<String, dynamic> params) async {
  final reminderId = (params["reminderId"] ?? "").toString();
  final voiceText = (params["voiceText"] ?? "").toString();
  final firedAt = DateTime.now().toLocal();
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

class OutdoorAlarmService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    tz.initializeTimeZones();

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings("@mipmap/ic_launcher"),
    );
    await _notifications.initialize(initSettings);

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
    await androidPlugin?.createNotificationChannel(channel);
    _initialized = true;
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
      final exactStatus = await Permission.scheduleExactAlarm.request();
      if (kDebugMode) {
        debugPrint("alarm permission exact alarm status: $exactStatus");
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("alarm permission exact alarm request failed: $e");
      }
    }
  }

  static Future<void> syncReminder(ReminderModel reminder) async {
    await initialize();
    await ensurePermissions();
    final due = DateTime.tryParse(reminder.timestamp);
    final nowLocal = DateTime.now().toLocal();
    final dueLocal = due?.toLocal();
    if (kDebugMode) {
      debugPrint(
        "sync reminder payload => reminderId=${reminder.id} title=${reminder.title} "
        "message=${reminder.message} rawDueTime=${reminder.timestamp} "
        "parsedDueLocal=$dueLocal nowLocal=$nowLocal",
      );
    }
    if (due == null) {
      if (kDebugMode) {
        debugPrint("alarm schedule skipped: invalid dueTime ${reminder.timestamp}");
      }
      return;
    }
    if (reminder.status != "pending") {
      await cancelReminder(reminder.id);
      return;
    }
    final nowUtc = DateTime.now().toUtc();
    final dueUtc = due.toUtc();
    if (!dueUtc.isAfter(nowUtc)) {
      if (kDebugMode) {
        debugPrint(
          "alarm schedule skipped: dueTime not in future id=${reminder.id} "
          "dueLocal=${dueUtc.toLocal()} nowLocal=${nowUtc.toLocal()}",
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
    final payload = jsonEncode({
      "reminderId": reminder.id,
      "title": reminder.title,
      "message": reminder.message,
      "dueTime": reminder.timestamp,
      "mode": reminder.mode,
      "status": reminder.status,
    });

    try {
      await _notifications.zonedSchedule(
        reminderIntId,
        "Reminder: ${reminder.title}",
        reminder.message.isEmpty ? "Please check your reminder now." : reminder.message,
        tz.TZDateTime.from(dueUtc, tz.UTC),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _alarmChannelId,
            _alarmChannelName,
            channelDescription: _alarmChannelDescription,
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            sound: RawResourceAndroidNotificationSound("reminder_alarm"),
            category: AndroidNotificationCategory.alarm,
            ticker: "Outdoor alarm fired",
            fullScreenIntent: true,
          ),
        ),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint("alarm custom sound scheduling failed, fallback default: $e");
      }
      await _notifications.zonedSchedule(
        reminderIntId,
        "Reminder: ${reminder.title}",
        reminder.message.isEmpty ? "Please check your reminder now." : reminder.message,
        tz.TZDateTime.from(dueUtc, tz.UTC),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _alarmChannelId,
            _alarmChannelName,
            channelDescription: _alarmChannelDescription,
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.alarm,
            ticker: "Outdoor alarm fired",
            fullScreenIntent: true,
          ),
        ),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
    }

    await AndroidAlarmManager.oneShotAt(
      dueUtc.toLocal(),
      _voiceAlarmIdForReminder(reminder.id),
      outdoorVoiceAlarmCallback,
      exact: true,
      wakeup: true,
      allowWhileIdle: true,
      params: {
        "reminderId": reminder.id,
        "voiceText": voiceText,
      },
    );

    await _markScheduled(reminder.id, reminder.timestamp);
    if (kDebugMode) {
      debugPrint(
        "alarm scheduled timestamp=${DateTime.now().toLocal()} id=${reminder.id} "
        "dueLocal=${dueUtc.toLocal()} notifId=$reminderIntId",
      );
    }
  }

  static Future<void> syncFromHistory(List<ReminderModel> reminders) async {
    await initialize();
    final seenIds = <String>{};
    for (final reminder in reminders) {
      seenIds.add(reminder.id);
      if (reminder.mode == "outdoor") {
        await syncReminder(reminder);
      } else {
        await cancelReminder(reminder.id);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final existingMap = _decodeMap(prefs.getString(_scheduledRemindersPref));
    for (final existingId in existingMap.keys) {
      if (!seenIds.contains(existingId)) {
        await cancelReminder(existingId);
      }
    }
  }

  static Future<void> cancelReminder(String reminderId) async {
    await initialize();
    final reminderIntId = _idForReminder(reminderId);
    await _notifications.cancel(reminderIntId);
    await AndroidAlarmManager.cancel(_voiceAlarmIdForReminder(reminderId));
    await _removeScheduled(reminderId);
    final voiceMap = await _loadVoiceMap();
    voiceMap.remove(reminderId);
    await _saveVoiceMap(voiceMap);
    if (kDebugMode) {
      debugPrint("alarm cancelled: id=$reminderId notifId=$reminderIntId");
    }
  }

  static int _idForReminder(String reminderId) =>
      reminderId.hashCode & 0x7fffffff;
  static int _voiceAlarmIdForReminder(String reminderId) =>
      ((reminderId.hashCode & 0x7fffffff) % 100000000) + 100000000;

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
