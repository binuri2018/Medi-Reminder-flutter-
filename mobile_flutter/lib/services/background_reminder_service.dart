import "dart:convert";
import "dart:ui";

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
  // CRITICAL ORDER for background isolates:
  //   1. WidgetsFlutterBinding.ensureInitialized() spins up the engine.
  //   2. DartPluginRegistrant.ensureInitialized() wires up plugin method
  //      channels for THIS isolate. Without this, every plugin call
  //      (SharedPreferences, http, AndroidAlarmManager, ...) silently
  //      no-ops.
  // Running with both initialized is the only way the WorkManager-driven
  // sync can actually schedule local notifications when the user keeps
  // the app fully closed for long stretches.
  WidgetsFlutterBinding.ensureInitialized();
  try {
    DartPluginRegistrant.ensureInitialized();
  } catch (_) {
    // intentional swallow: ensureInitialized is a no-op on subsequent
    // calls and may not be needed when running in the main isolate.
  }
  Workmanager().executeTask((task, _) async {
    await BackgroundReminderService.checkAndSyncBackgroundReminder();
    return true;
  });
}

class BackgroundReminderService {
  /// Periodic frequency of the WorkManager safety net. Android enforces a
  /// 15-minute floor for periodic tasks, so anything tighter is silently
  /// rounded up. This is the only mechanism keeping the phone in sync with
  /// the backend while the app is fully closed (FCM is disabled in this
  /// build), so 15 minutes is also our worst-case detection latency for a
  /// brand-new reminder created via the web UI.
  static const Duration _frequency = Duration(minutes: 15);

  static Future<void> initialize() async {
    // CRITICAL: Always pass `isInDebugMode: false`. The workmanager package
    // shows a sticky foreground notification with text like
    //   "dartTask: outdoorReminderBackgroundTask"
    //   "inputData: not found"
    // whenever this flag is true. That popup is a debug aid, not a real
    // reminder, so we must keep it disabled (even in debug builds) so that
    // only the OutdoorAlarmService notifications are user-visible.
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
    await Workmanager().registerPeriodicTask(
      _taskUniqueName,
      _backgroundTaskName,
      frequency: _frequency,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
    if (kDebugMode) {
      debugPrint(
        "WorkManager initialized silently (debug notification suppressed) "
        "frequency=${_frequency.inMinutes}min",
      );
    }
  }

  /// Runs every WorkManager cycle (~15 min) and on app start. Pulls full
  /// history from the backend and feeds it into [OutdoorAlarmService.syncFromHistory]
  /// so every pending+outdoor reminder gets a local exact alarm.
  ///
  /// Why history (not /latest) is the right choice here:
  ///   * Future reminders aren't returned by /latest until the dispatcher
  ///     fires them at their dueTime. So a reminder created via the web at
  ///     14:00 for 14:30 wouldn't show up in /latest until 14:30, by which
  ///     time we've already missed the popup window.
  ///   * /history returns every reminder the user can see in their list,
  ///     including future ones. Feeding all of them into syncFromHistory
  ///     lets us schedule a `zonedSchedule` for each future dueTime, and
  ///     Android's AlarmManager keeps that schedule alive even after the
  ///     app is killed.
  static Future<void> checkAndSyncBackgroundReminder() async {
    if (kDebugMode) {
      debugPrint("WorkManager sync executed silently");
    }
    final mode = await _safeGetMode();
    if (mode == null) {
      if (kDebugMode) {
        debugPrint("WorkManager sync skipped: mode unavailable");
      }
      return;
    }
    if (mode.trim().toLowerCase() != "outdoor") {
      if (kDebugMode) {
        debugPrint("WorkManager sync skipped: mode=$mode");
      }
      return;
    }

    final history = await _safeGetHistory();
    if (history == null) {
      // Couldn't talk to the backend. Fall back to /latest so a single
      // pending reminder still gets a chance to fire.
      await _legacyLatestPath();
      return;
    }

    if (kDebugMode) {
      debugPrint(
        "WorkManager sync fetched history: count=${history.length}",
      );
    }
    await OutdoorAlarmService.syncFromHistory(
      history,
      headlessWorker: true,
    );
  }

  /// Falls back to the original /latest behaviour when /history is
  /// unreachable. Better than doing nothing for the next 15 minutes.
  static Future<void> _legacyLatestPath() async {
    final latest = await _safeGetLatestReminder();
    if (latest == null) return;

    final status = latest["status"]?.toString() ?? "";
    final reminderId = latest["id"]?.toString() ?? "";
    if (!isReminderPending(status)) {
      if (reminderId.isNotEmpty) {
        await OutdoorAlarmService.cancelReminder(reminderId);
      }
      return;
    }

    final reminder = ReminderModel(
      id: reminderId,
      title: latest["title"]?.toString() ?? "Reminder",
      message: latest["message"]?.toString() ?? "",
      timestamp: latest["timestamp"]?.toString() ?? "",
      mode: latest["mode"]?.toString() ?? "outdoor",
      status: status,
    );
    await OutdoorAlarmService.syncReminder(
      reminder,
      headlessNotificationSetup: true,
    );
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

  static Future<List<ReminderModel>?> _safeGetHistory() async {
    try {
      final uri = Uri.parse(
        "${ApiConfig.baseUrl}/api/reminders/history?limit=30",
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body);
      // Tolerate both shapes: `{"data": [...]}` and a top-level list.
      List<dynamic> raw;
      if (body is List) {
        raw = body;
      } else if (body is Map<String, dynamic> && body["data"] is List) {
        raw = body["data"] as List<dynamic>;
      } else {
        return null;
      }
      return raw
          .whereType<Map<String, dynamic>>()
          .map(
            (json) => ReminderModel(
              id: json["id"]?.toString() ?? "",
              title: json["title"]?.toString() ?? "Reminder",
              message: json["message"]?.toString() ?? "",
              timestamp: json["timestamp"]?.toString() ?? "",
              mode: json["mode"]?.toString() ?? "outdoor",
              status: json["status"]?.toString() ?? "pending",
            ),
          )
          .toList();
    } catch (e) {
      if (kDebugMode) {
        debugPrint("WorkManager history fetch failed: $e");
      }
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
