from datetime import datetime, timezone
import logging
from typing import Any, Dict

from models.reminder import AutoModeSettingEnum, ModeEnum, ModeSourceEnum, ModeUpdateRequest
from storage.state_store import StateStore


class ModeService:
    def __init__(self, store: StateStore):
        self._store = store
        self._logger = logging.getLogger(__name__)

    def get_mode(self) -> ModeEnum:
        return ModeEnum(self._store.get_mode())

    def set_mode(self, mode: ModeEnum) -> ModeEnum:
        saved = self._store.set_mode(mode.value)
        return ModeEnum(saved)

    def get_mode_state(self) -> Dict[str, Any]:
        state = self._store.get_mode_state()
        return {
            "mode": ModeEnum(state["mode"]),
            "source": ModeSourceEnum(state["source"]),
            "autoModeSetting": AutoModeSettingEnum(state["autoModeSetting"]),
            "deviceId": state.get("deviceId"),
            "lastRssi": state.get("lastRssi"),
            "lastUpdateTime": state.get("lastUpdateTime"),
        }

    def update_mode(self, request: ModeUpdateRequest) -> Dict[str, Any]:
        current = self._store.get_mode_state()

        if request.autoModeSetting is not None:
            current["autoModeSetting"] = request.autoModeSetting.value

        if (
            request.source == ModeSourceEnum.bluetooth_auto
            and current.get("autoModeSetting", "manual") != AutoModeSettingEnum.bluetooth_auto.value
        ):
            # Manual mode setting is authoritative; auto updates are ignored.
            if request.rssi is not None:
                current["lastRssi"] = request.rssi
            if request.deviceId:
                current["deviceId"] = request.deviceId
            self._logger.info("Ignored bluetooth_auto mode update while auto mode setting is manual")
            return self._store.set_mode_state(current)

        current["mode"] = request.mode.value
        current["source"] = request.source.value
        current["deviceId"] = request.deviceId or current.get("deviceId")
        if request.rssi is not None:
            current["lastRssi"] = request.rssi
        current["lastUpdateTime"] = (
            request.timestamp.isoformat()
            if request.timestamp is not None
            else datetime.now(timezone.utc).isoformat()
        )
        reason = request.reason or "manual change"
        self._logger.info(
            "Mode updated to %s via %s (device=%s, rssi=%s, reason=%s)",
            current["mode"],
            current["source"],
            current.get("deviceId"),
            current.get("lastRssi"),
            reason,
        )
        return self._store.set_mode_state(current)
