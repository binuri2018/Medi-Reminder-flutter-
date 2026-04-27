from fastapi import APIRouter, HTTPException, Query
import logging

from models.reminder import (
    MobileTokenRegisterRequest,
    MobileTokenRegisterResponse,
    ReminderAckRequest,
    ReminderPayload,
    ReminderSendRequest,
)
from services.container import dispatcher_service, store

router = APIRouter(tags=["reminders"])
logger = logging.getLogger(__name__)


@router.post("/reminders/send", response_model=ReminderPayload)
def send_reminder(payload: ReminderSendRequest):
    return dispatcher_service.dispatch(payload)


@router.post("/devices/mobile-token", response_model=MobileTokenRegisterResponse)
def register_mobile_token(payload: MobileTokenRegisterRequest):
    logger.info(
        "Registering mobile FCM token (platform=%s, device_id=%s)",
        payload.platform,
        payload.device_id,
    )
    saved = store.set_mobile_device_token(
        token=payload.token,
        platform=payload.platform,
        device_id=payload.device_id,
    )
    return {
        "status": "ok",
        "token": saved["token"],
        "platform": saved.get("platform", "android"),
    }


@router.get("/reminders/latest")
def get_latest_reminder():
    latest = dispatcher_service.latest()
    return {"data": latest}


@router.get("/reminders/history")
def get_reminder_history(limit: int = Query(default=50, ge=1, le=500)):
    return {"data": dispatcher_service.history(limit=limit)}


@router.post("/reminders/{reminder_id}/ack")
def acknowledge_reminder(reminder_id: str, payload: ReminderAckRequest):
    ack = dispatcher_service.acknowledge(reminder_id, payload.acknowledged_by or "mobile")
    if not ack:
        raise HTTPException(status_code=404, detail="Reminder not found")
    return {"data": ack}


@router.post("/reminders/{reminder_id}/sync")
def mark_reminder_synced(reminder_id: str):
    synced = dispatcher_service.mark_synced(reminder_id)
    if not synced:
        raise HTTPException(status_code=404, detail="Acknowledged reminder not found")
    return {"data": synced}
