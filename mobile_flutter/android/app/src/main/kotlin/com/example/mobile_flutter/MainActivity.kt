package com.example.mobile_flutter

import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val exactAlarmChannel = "com.example.mobile_flutter/exact_alarm"
    private val foregroundServiceChannel =
        "com.example.mobile_flutter/foreground_service"

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Start the persistent foreground service as soon as the activity
        // hits onCreate. This is the earliest hook that is guaranteed to run
        // every cold start AND every warm resume — the OS does not always
        // call configureFlutterEngine on warm restarts (cached engine), so
        // doing the start here, not there, avoids leaving the process
        // unprotected after a process restart.
        OutdoorReminderForegroundService.start(applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            exactAlarmChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canScheduleExactAlarms" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        result.success(am.canScheduleExactAlarms())
                    } else {
                        result.success(true)
                    }
                }
                "openExactAlarmSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // Dart-side hook so the Flutter layer can re-start the foreground
        // service if it ever needs to (e.g. after the user revokes a
        // permission and re-grants it). The service's start() is idempotent
        // so calling it multiple times is safe.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            foregroundServiceChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    OutdoorReminderForegroundService.start(applicationContext)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
