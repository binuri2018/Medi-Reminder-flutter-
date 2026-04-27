from datetime import datetime
import logging
from typing import Any, Dict, List, Optional

from models.reminder import ModeEnum, ReminderPayload, ReminderSendRequest
from services.fcm_service import FcmService
from services.mode_service import ModeService
from storage.state_store import StateStore


class DispatcherService:
    def __init__(self, mode_service: ModeService, store: StateStore, fcm_service: FcmService):
        self._mode_service = mode_service
        self._store = store
        self._fcm_service = fcm_service
        self._logger = logging.getLogger(__name__)

    def dispatch(self, request: ReminderSendRequest) -> ReminderPayload:
        mode = self._mode_service.get_mode()
        payload = ReminderPayload(
            id=request.id,
            title=request.title,
            message=request.message,
            timestamp=request.timestamp,
            mode=mode,
            status="pending",
        )
        if mode == ModeEnum.outdoor:
            self._store.set_latest_reminder(payload.model_dump(mode="json"))
            token = self._store.get_mobile_device_token()
            sent = self._fcm_service.send_outdoor_reminder(token=token or "", reminder=payload)
            if sent:
                self._logger.info("Outdoor reminder dispatched via FCM (id=%s)", payload.id)
            else:
                self._logger.warning("Outdoor reminder FCM dispatch failed/skipped (id=%s)", payload.id)
        return payload

    def latest(self) -> Optional[Dict[str, Any]]:
        return self._store.get_latest_reminder()

    def history(self, limit: Optional[int] = None) -> List[Dict[str, Any]]:
        items = self._store.get_history()

        def parse_timestamp(value: Optional[str]) -> datetime:
            if not value:
                return datetime.min
            try:
                return datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                return datetime.min

        sorted_items = sorted(
            items,
            key=lambda x: parse_timestamp(x.get("timestamp")),
            reverse=True,
        )
        if limit is None or limit <= 0:
            return sorted_items
        return sorted_items[:limit]

    def acknowledge(self, reminder_id: str, acknowledged_by: str) -> Optional[Dict[str, Any]]:
        return self._store.acknowledge(reminder_id, acknowledged_by)

    def mark_synced(self, reminder_id: str) -> Optional[Dict[str, Any]]:
        return self._store.mark_synced(reminder_id)
