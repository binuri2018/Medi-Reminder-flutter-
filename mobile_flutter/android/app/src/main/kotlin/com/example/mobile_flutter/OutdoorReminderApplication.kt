package com.example.mobile_flutter

import android.util.Log
import io.flutter.app.FlutterApplication

/**
 * Starts [OutdoorReminderForegroundService] whenever the VM process spins up —
 * launcher, push wake, BOOT, job worker, anything. Dart code from
 * firebaseMessagingBackgroundHandler cannot reach MethodChannel handlers that
 * are only registered via MainActivity.configureFlutterEngine, but the native
 * Application hook always runs first and restores the foreground service before
 * FCM delegates to Flutter.
 */
class OutdoorReminderApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        try {
            OutdoorReminderForegroundService.start(applicationContext)
        } catch (e: Exception) {
            Log.e(
                "OutdoorReminderApplication",
                "foreground service bootstrap failed: ${e.message}",
                e,
            )
        }
    }
}
