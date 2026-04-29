package com.example.mobile_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Ensures the keep-alive foreground service starts after reboot or app upgrade
 * without requiring the user to open the launcher activity first.
 */
class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED
        ) {
            return
        }
        try {
            OutdoorReminderForegroundService.start(context.applicationContext)
        } catch (e: Exception) {
            Log.e("BootCompletedReceiver", "start foreground service failed", e)
        }
    }
}
