from datetime import datetime
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


class ModeEnum(str, Enum):
    indoor = "indoor"
    outdoor = "outdoor"


class ModeSourceEnum(str, Enum):
    manual = "manual"
    bluetooth_auto = "bluetooth_auto"


class AutoModeSettingEnum(str, Enum):
    manual = "manual"
    bluetooth_auto = "bluetooth_auto"


class ReminderStatus(str, Enum):
    pending = "pending"
    acknowledged = "acknowledged"
    synced = "synced"


class ReminderPayload(BaseModel):
    id: str = Field(..., min_length=1)
    title: str = Field(..., min_length=1)
    message: str = ""
    timestamp: datetime
    mode: ModeEnum
    status: ReminderStatus = ReminderStatus.pending


class ReminderAckRequest(BaseModel):
    acknowledged_by: Optional[str] = "mobile"


class ModeResponse(BaseModel):
    mode: ModeEnum


class ModeUpdateRequest(BaseModel):
    mode: ModeEnum
    source: ModeSourceEnum = ModeSourceEnum.manual
    deviceId: Optional[str] = None
    rssi: Optional[int] = None
    reason: Optional[str] = None
    timestamp: Optional[datetime] = None
    autoModeSetting: Optional[AutoModeSettingEnum] = None


class ModeStateResponse(BaseModel):
    mode: ModeEnum
    source: ModeSourceEnum = ModeSourceEnum.manual
    autoModeSetting: AutoModeSettingEnum = AutoModeSettingEnum.manual
    deviceId: Optional[str] = None
    lastRssi: Optional[int] = None
    lastUpdateTime: Optional[datetime] = None


class ReminderSendRequest(BaseModel):
    id: str = Field(..., min_length=1)
    title: str = Field(..., min_length=1)
    message: str = ""
    timestamp: datetime


class MobileTokenRegisterRequest(BaseModel):
    token: str = Field(..., min_length=1)
    platform: Optional[str] = "android"
    device_id: Optional[str] = None


class MobileTokenRegisterResponse(BaseModel):
    status: str = "ok"
    token: str
    platform: Optional[str] = "android"
