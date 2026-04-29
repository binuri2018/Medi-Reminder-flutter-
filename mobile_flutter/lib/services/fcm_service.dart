import "dart:developer" as dev;
import "dart:ui";

import "package:firebase_core/firebase_core.dart";
import "package:flutter/foundation.dart";
import "package:flutter/widgets.dart";
import "package:firebase_messaging/firebase_messaging.dart";
import "package:permission_handler/permission_handler.dart";

import "../firebase_options.dart";
import "api_service.dart";
import "../models/reminder_model.dart";
import "outdoor_alarm_service.dart";

@pragma("vm:entry-point")
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  try {
    DartPluginRegistrant.ensureInitialized();
  } catch (_) {}
  dev.log(
    "phone FCM received (background) messageId=${message.messageId} "
    "data=${message.data}",
    name: "FCM",
  );
  await FcmService.syncReminderFromMessage(message, source: "background");
}

class FcmService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  static Future<void> initialize({
    required ApiService api,
  }) async {
    // Background handler is registered in main.dart immediately after
    // Firebase.initializeApp — before this method runs.
    await _requestNotificationPermission();

    final token = await _messaging.getToken();
    if (kDebugMode) {
      debugPrint("FCM token fetched: ${token ?? "null"}");
    }
    if (token != null && token.isNotEmpty) {
      try {
        await api.registerMobileFcmToken(token: token, platform: "android");
        if (kDebugMode) {
          debugPrint("FCM token registration success");
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint("FCM token registration failed: $e");
        }
      }
    }

    _messaging.onTokenRefresh.listen((newToken) async {
      if (kDebugMode) {
        debugPrint("FCM token refreshed");
      }
      try {
        await api.registerMobileFcmToken(token: newToken, platform: "android");
        if (kDebugMode) {
          debugPrint("FCM refreshed token registration success");
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint("FCM refreshed token registration failed: $e");
        }
      }
    });

    FirebaseMessaging.onMessage.listen((message) async {
      dev.log(
        "phone FCM received (foreground) messageId=${message.messageId} "
        "data=${message.data}",
        name: "FCM",
      );
      await syncReminderFromMessage(message, source: "foreground");
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (kDebugMode) {
        debugPrint("FCM notification tapped: ${message.messageId}");
      }
    });
  }

  static Future<void> syncReminderFromMessage(
    RemoteMessage message, {
    String source = "unknown",
  }) async {
    try {
      final data = message.data;
      final reminderId = data["reminderId"] ?? "";
      final mode = data["mode"] ?? "";
      final status = data["status"] ?? "pending";
      final dueTime = data["dueTime"] ?? data["timestamp"] ?? "";
      final title = data["title"] ?? message.notification?.title ?? "Reminder";
      final msg = data["message"] ?? message.notification?.body ?? "";
      final parsedDueUtc = DateTime.tryParse(dueTime.toString())?.toUtc();
      final nowUtc = DateTime.now().toUtc();
      if (kDebugMode) {
        debugPrint(
          "FCM reminder payload ($source) => reminderId=$reminderId title=$title "
          "message=$msg rawDueTime=$dueTime parsedDueUtc=$parsedDueUtc nowUtc=$nowUtc",
        );
      }
      if (reminderId.toString().isEmpty || dueTime.toString().isEmpty) {
        dev.log(
          "FCM reminder sync skipped: missing reminderId/dueTime source=$source",
          name: "FCM",
        );
        return;
      }
      // Critical guard: never schedule/notify a non-pending reminder
      // (acknowledged/done/completed/...) regardless of casing.
      if (!isReminderPending(status.toString())) {
        await OutdoorAlarmService.cancelReminder(reminderId.toString());
        dev.log(
          "FCM reminder cancelled local alarm: status=${status.toString()} "
          "id=$reminderId source=$source",
          name: "FCM",
        );
        return;
      }
      if (mode.toString().trim().toLowerCase() != "outdoor") {
        await OutdoorAlarmService.cancelReminder(reminderId.toString());
        return;
      }
      final dueIsFuture =
          parsedDueUtc != null && parsedDueUtc.isAfter(nowUtc);
      // Pending + outdoor: [syncReminder] chooses immediate vs exact schedule.
      // Primary discovery path; polling/history/WorkManager remain backup.
      if (parsedDueUtc != null && !dueIsFuture) {
        dev.log(
          "FCM sync reminder (due now or past, immediate/stale handling) "
          "id=$reminderId dueTime=$dueTime source=$source",
          name: "FCM",
        );
      }
      final reminder = ReminderModel(
        id: reminderId.toString(),
        title: title.toString(),
        message: msg.toString(),
        timestamp: dueTime.toString(),
        mode: mode.toString(),
        status: status.toString(),
      );
      // Always run the full local-notification path (with Done action +
      // custom sound) regardless of whether the FCM payload also carried a
      // `notification` block. We learned the hard way that Samsung One UI
      // throttles the OS-level auto-display after the first heads-up, so we
      // need the local notification as a guaranteed second path. Our local
      // notif uses a stable id derived from reminder.id, so even if both
      // fire the user sees a single deduped notification per reminder in
      // practice (different cosmetic but same semantic event).
      await OutdoorAlarmService.syncReminder(
        reminder,
        headlessNotificationSetup: source == "background",
        // Closed/terminated delivery can be delayed by OEM background policy.
        // For push-originated single reminders, prefer a late popup over
        // silently dropping as stale.
        allowStaleImmediate: source == "background",
      );
      if (dueIsFuture) {
        dev.log(
          "FCM scheduled reminder id=$reminderId dueTime=$dueTime source=$source",
          name: "FCM",
        );
      }
    } catch (e, st) {
      dev.log(
        "FCM reminder sync failed: $e",
        name: "FCM",
        error: e,
        stackTrace: st,
      );
    }
  }

  static Future<void> _requestNotificationPermission() async {
    try {
      final notif = await Permission.notification.request();
      if (kDebugMode) {
        debugPrint("notification permission status: $notif");
      }
      await _messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );
    } catch (_) {
      // Keep app usable even if permission APIs are unavailable.
    }
  }
}
