import logging
import os
from pathlib import Path
from typing import Optional

from models.reminder import ReminderPayload

logger = logging.getLogger(__name__)


class FcmService:
    def __init__(self):
        self._messaging = None
        self._initialized = False
        self._init_error: Optional[str] = None

    def _ensure_initialized(self) -> bool:
        if self._initialized:
            return True
        if self._init_error is not None:
            return False
        try:
            import firebase_admin
            from firebase_admin import credentials, messaging

            creds_path = os.getenv("FIREBASE_SERVICE_ACCOUNT_PATH", "").strip()
            if not creds_path:
                # Optional FCM mode; backend remains operational without it.
                self._init_error = "FIREBASE_SERVICE_ACCOUNT_PATH not configured"
                logger.warning(self._init_error)
                return False

            resolved = Path(creds_path)
            if not resolved.exists():
                self._init_error = f"Firebase service account not found at {resolved}"
                logger.error(self._init_error)
                return False

            if not firebase_admin._apps:
                cred = credentials.Certificate(str(resolved))
                firebase_admin.initialize_app(cred)

            self._messaging = messaging
            self._initialized = True
            logger.info("FCM service initialized successfully")
            return True
        except Exception as exc:
            self._init_error = f"FCM init failed: {exc}"
            logger.exception(self._init_error)
            return False

    def send_outdoor_reminder(self, token: str, reminder: ReminderPayload) -> bool:
        if not token:
            logger.warning("Skipping FCM send: no mobile token registered")
            return False
        if not self._ensure_initialized():
            logger.warning("Skipping FCM send: service not initialized")
            return False
        assert self._messaging is not None
        try:
            # Hybrid payload: notification + data, both high priority.
            #
            # Why hybrid:
            #  - Data-only used to be the only payload, but on aggressive OEMs
            #    (Samsung One UI "Sleeping apps", Xiaomi MIUI background limits,
            #    etc.) the data-only background handler can be silently delayed
            #    or skipped when the app is closed, which is the exact symptom
            #    users were hitting (no popup unless app is open).
            #  - With a `notification` block, Android itself shows the popup
            #    when the app is in background or killed, regardless of OEM
            #    background restrictions.
            #
            # Foreground behavior is preserved:
            #  - When the app is in foreground, FCM does NOT auto-display the
            #    notification block; only the Dart `onMessage` listener fires,
            #    which routes through `syncReminder` and posts our local
            #    notification (with the Done action + custom alarm sound).
            #  - We add a `tag` so Android dedupes if both system and local
            #    fire on the same device for the same reminder id.
            #
            # The Done action and custom sound stay attached to the local
            # notification (foreground path). For background/killed the user
            # at least gets a reliable system popup; tapping it opens the app.
            # `channel_id` makes Android use the local channel
            # (`outdoor_alarm_channel_v3`) which carries our custom alarm sound
            # and Importance.max. `tag = reminder.id` lets the system replace
            # an existing system notification for the same reminder instead of
            # stacking duplicates.
            android_notification = self._messaging.AndroidNotification(
                channel_id="outdoor_alarm_channel_v3",
                priority="max",
                visibility="public",
                tag=reminder.id,
                click_action="FLUTTER_NOTIFICATION_CLICK",
            )
            message = self._messaging.Message(
                token=token,
                android=self._messaging.AndroidConfig(
                    priority="high",
                    notification=android_notification,
                ),
                notification=self._messaging.Notification(
                    title=reminder.title,
                    body=reminder.message or "Please check your reminder now.",
                ),
                data={
                    "reminderId": reminder.id,
                    "title": reminder.title,
                    "message": reminder.message or "Please check your reminder now.",
                    "dueTime": reminder.timestamp.isoformat(),
                    "mode": reminder.mode.value,
                    "outdoor": "true" if reminder.mode.value == "outdoor" else "false",
                    "status": reminder.status.value,
                    "timestamp": reminder.timestamp.isoformat(),
                    "channelId": "outdoor_alarm_channel_v3",
                },
            )
            result = self._messaging.send(message)
            logger.info(
                "backend FCM data push sent reminder_id=%s dueTime=%s mode=%s "
                "status=%s title=%s message_id=%s",
                reminder.id,
                reminder.timestamp.isoformat(),
                reminder.mode.value,
                reminder.status.value,
                reminder.title,
                result,
            )
            return True
        except Exception as exc:
            logger.exception("FCM send failed: %s", exc)
            return False
