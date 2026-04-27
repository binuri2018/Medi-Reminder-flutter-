import "dart:convert";

import "package:flutter/foundation.dart";
import "package:flutter/widgets.dart";
import "package:http/http.dart" as http;
import "package:workmanager/workmanager.dart";

import "../config/api_config.dart";
import "../models/reminder_model.dart";
import "outdoor_alarm_service.dart";

const String _backgroundTaskName = "outdoorReminderBackgroundTask";
const String _taskUniqueName = "outdoor-reminder-background-worker";

@pragma("vm:entry-point")
void callbackDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    await BackgroundReminderService.checkAndSyncBackgroundReminder();
    return true;
  });
}

class BackgroundReminderService {
  static Future<void> initialize() async {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: kDebugMode);
    await Workmanager().registerPeriodicTask(
      _taskUniqueName,
      _backgroundTaskName,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }

  static Future<void> checkAndSyncBackgroundReminder() async {
    if (kDebugMode) {
      debugPrint("WorkManager sync executed silently");
    }
    final mode = await _safeGetMode();
    if (mode != "outdoor") return;

    final latest = await _safeGetLatestReminder();
    if (latest == null) return;

    final status = latest["status"]?.toString() ?? "";
    if (status != "pending") return;

    final reminder = ReminderModel(
      id: latest["id"]?.toString() ?? "",
      title: latest["title"]?.toString() ?? "Reminder",
      message: latest["message"]?.toString() ?? "",
      timestamp: latest["timestamp"]?.toString() ?? "",
      mode: latest["mode"]?.toString() ?? "outdoor",
      status: status,
    );
    await OutdoorAlarmService.syncReminder(reminder);
  }

  static Future<String?> _safeGetMode() async {
    try {
      final uri = Uri.parse("${ApiConfig.baseUrl}/api/mode");
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body["mode"]?.toString();
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _safeGetLatestReminder() async {
    try {
      final uri = Uri.parse("${ApiConfig.baseUrl}/api/reminders/latest");
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final data = body["data"];
      if (data is! Map<String, dynamic>) return null;
      return data;
    } catch (_) {
      return null;
    }
  }
}
