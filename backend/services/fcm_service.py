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
            # IMPORTANT: We deliberately send a *data-only* high-priority push.
            #
            # Why no `notification:` block?
            # The Flutter app renders the real reminder notification locally
            # via OutdoorAlarmService so it can attach the "Done" action,
            # custom alarm sound (res/raw/reminder_alarm) and full-screen
            # intent. If we ALSO sent a notification block, Android would
            # auto-display its own basic notification when the app is
            # backgrounded/killed -- causing the user to see two notifications
            # for the same reminder, with the auto-displayed one missing the
            # Done button. Data-only + priority=high still wakes the app's
            # background isolate (firebaseMessagingBackgroundHandler) so the
            # local notification fires reliably in foreground, background and
            # killed states.
            #
            # The channel_id below is a hint; the Flutter app is the actual
            # source of truth for channel settings. It must match the channel
            # ID used in OutdoorAlarmService (`outdoor_alarm_channel_v2`).
            message = self._messaging.Message(
                token=token,
                android=self._messaging.AndroidConfig(
                    priority="high",
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
            logger.info("FCM sent successfully: %s", result)
            return True
        except Exception as exc:
            logger.exception("FCM send failed: %s", exc)
            return False
