import "package:flutter/foundation.dart";
import "package:firebase_messaging/firebase_messaging.dart";
import "package:permission_handler/permission_handler.dart";

import "api_service.dart";
import "../models/reminder_model.dart";
import "outdoor_alarm_service.dart";

@pragma("vm:entry-point")
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (kDebugMode) {
    debugPrint("FCM payload received (background): ${message.data}");
  }
  await FcmService.syncReminderFromMessage(message);
}

class FcmService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  static Future<void> initialize({
    required ApiService api,
  }) async {
    await _requestNotificationPermission();

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

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
      if (kDebugMode) {
        debugPrint("FCM payload received (foreground): ${message.data}");
      }
      await syncReminderFromMessage(message);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (kDebugMode) {
        debugPrint("FCM notification tapped: ${message.messageId}");
      }
    });
  }

  static Future<void> syncReminderFromMessage(RemoteMessage message) async {
    try {
      final data = message.data;
      final reminderId = data["reminderId"] ?? "";
      final mode = data["mode"] ?? "";
      final status = data["status"] ?? "pending";
      final dueTime = data["dueTime"] ?? data["timestamp"] ?? "";
      final title = data["title"] ?? message.notification?.title ?? "Reminder";
      final msg = data["message"] ?? message.notification?.body ?? "";
      final parsedDue = DateTime.tryParse(dueTime.toString())?.toLocal();
      final nowLocal = DateTime.now();
      if (kDebugMode) {
        debugPrint(
          "FCM reminder payload => reminderId=$reminderId title=$title message=$msg "
          "rawDueTime=$dueTime parsedDueLocal=$parsedDue nowLocal=$nowLocal",
        );
      }
      if (reminderId.toString().isEmpty || dueTime.toString().isEmpty) {
        if (kDebugMode) {
          debugPrint("FCM reminder sync skipped: missing reminderId/dueTime");
        }
        return;
      }
      if (mode.toString() != "outdoor") {
        await OutdoorAlarmService.cancelReminder(reminderId.toString());
        return;
      }
      final reminder = ReminderModel(
        id: reminderId.toString(),
        title: title.toString(),
        message: msg.toString(),
        timestamp: dueTime.toString(),
        mode: mode.toString(),
        status: status.toString(),
      );
      await OutdoorAlarmService.syncReminder(reminder);
      if (kDebugMode) {
        debugPrint("FCM reminder synced: id=${reminder.id}");
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("FCM reminder sync failed: $e");
      }
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
