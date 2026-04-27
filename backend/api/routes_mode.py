from fastapi import APIRouter

from models.reminder import ModeStateResponse, ModeUpdateRequest
from services.container import mode_service

router = APIRouter(tags=["mode"])


@router.get("/mode", response_model=ModeStateResponse)
def get_mode():
    return mode_service.get_mode_state()


@router.post("/mode", response_model=ModeStateResponse)
def set_mode(payload: ModeUpdateRequest):
    return mode_service.update_mode(payload)
