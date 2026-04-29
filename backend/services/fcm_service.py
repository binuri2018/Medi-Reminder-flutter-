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
            # Data-only high-priority push.
            #
            # We deliberately do NOT send a `notification:` block. The Flutter
            # client runs a persistent foreground service
            # (OutdoorReminderForegroundService) that keeps the app process
            # alive across all states (foreground / background / swiped from
            # recents), so the Dart `firebaseMessagingBackgroundHandler` is
            # guaranteed to run for every push. That handler renders the real
            # reminder notification locally via OutdoorAlarmService, which is
            # the only path that carries the "Done" action button, the
            # full-screen alarm intent and the custom alarm sound.
            #
            # Sending a `notification` block alongside the data was attempted
            # earlier and produced two regressions on Samsung One UI:
            #   1. The OS auto-displayed a bare notification with NO Done
            #      action — the user could not acknowledge from the popup,
            #      because the FCM-side notification has no actions wired up.
            #   2. After the first heads-up, Samsung's adaptive HUN throttle
            #      silenced subsequent system-displayed notifications, so
            #      reminders #2, #3, ... never popped while the app was
            #      closed.
            # The foreground service removes the need for that fallback and
            # gives us a single, predictable display path.
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
