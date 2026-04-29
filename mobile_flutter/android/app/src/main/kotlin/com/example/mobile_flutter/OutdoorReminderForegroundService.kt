package com.example.mobile_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Persistent low-importance foreground service that prevents Samsung One UI /
 * Xiaomi MIUI / Huawei EMUI from putting the app process into a "sleeping app"
 * or "deep sleep" state. As long as this service is running:
 *
 *  - The OS treats the app as user-visible, so Firebase Messaging is allowed
 *    to wake `firebaseMessagingBackgroundHandler` immediately when a push
 *    arrives (no 2-3 minute OEM delay).
 *  - The local notification path inside `OutdoorAlarmService` runs reliably
 *    for every reminder, which means the "Done" action button always shows
 *    and works (the bare FCM auto-displayed system notification has no Done
 *    button, which is why the user previously saw the action go missing
 *    after the app was closed).
 *  - Android's adaptive notification HUN throttle does not kick in after the
 *    first heads-up, because the app is in the active bucket.
 *
 * This is the SAME pattern WhatsApp / Telegram / Tasker / AlarmDroid use on
 * Android. It is the only reliable answer to OEM background restrictions
 * outside of OEM-specific whitelisting.
 *
 * The notification is intentionally minimal-importance with no sound, no
 * vibration, no badge, hidden on lock screen, and category=service so the
 * user does not perceive it as a real notification — it sits silently in
 * the bottom of the tray.
 */
class OutdoorReminderForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "outdoor_reminder_keep_alive_v1"
        const val CHANNEL_NAME = "Reminder service"
        const val CHANNEL_DESCRIPTION =
            "Keeps the reminder app responsive in the background so notifications are not delayed."
        const val NOTIFICATION_ID = 4242

        /**
         * Idempotent. Safe to call from anywhere (Activity, BroadcastReceiver,
         * boot receiver, ...). On Android 8+ uses startForegroundService so
         * the OS allows the service to call startForeground within 5s; on
         * older versions falls back to the plain startService API.
         */
        fun start(context: Context) {
            val intent = Intent(context, OutdoorReminderForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // ForegroundServiceStartNotAllowedException can fire when the
                // OS treats the launch context as background (Android 12+).
                // In that case the next foreground app launch will retry.
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+ requires an explicit foreground service type. We
            // declare dataSync because we are keeping a network/FCM-driven
            // sync loop responsive.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY: if the OS reaps the service to free memory (rare
        // because we are foreground), it is recreated as soon as resources
        // allow.
        return START_STICKY
    }

    /**
     * The notification channel is created at IMPORTANCE_MIN with no sound or
     * vibration. On modern Android the user can hide such notifications
     * entirely from the status bar — they still satisfy the foreground
     * service requirement.
     */
    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = CHANNEL_DESCRIPTION
            setShowBadge(false)
            enableVibration(false)
            enableLights(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_SECRET
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        // Tapping the keep-alive notification just opens the app's main
        // launcher activity. Helps the user re-open the app from anywhere.
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentPendingIntent = launchIntent?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            val pendingFlags =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            PendingIntent.getActivity(this, 0, it, pendingFlags)
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Reminders are active")
            .setContentText("Listening for new reminders.")
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)

        if (contentPendingIntent != null) {
            builder.setContentIntent(contentPendingIntent)
        }
        return builder.build()
    }
}
