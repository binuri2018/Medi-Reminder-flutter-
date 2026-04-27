import "package:flutter/material.dart";
import "package:firebase_core/firebase_core.dart";
import "package:flutter/foundation.dart";
import "package:android_alarm_manager_plus/android_alarm_manager_plus.dart";

import "config/api_config.dart";
import "firebase_options.dart";
import "screens/home_screen.dart";
import "services/api_service.dart";
import "services/background_reminder_service.dart";
import "services/fcm_service.dart";
import "services/outdoor_alarm_service.dart";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    debugPrint("API_BASE_URL = ${ApiConfig.baseUrl}");
  }
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await AndroidAlarmManager.initialize();
  await OutdoorAlarmService.initialize();
  await FcmService.initialize(api: ApiService());
  await BackgroundReminderService.initialize();
  runApp(const MobileReminderApp());
}

class MobileReminderApp extends StatelessWidget {
  const MobileReminderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Outdoor Reminder Simulator",
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
