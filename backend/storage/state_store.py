import json
from pathlib import Path
from threading import Lock
from typing import Any, Dict, List, Optional


class StateStore:
    def __init__(self, file_path: Optional[Path] = None):
        self._lock = Lock()
        self._file_path = file_path or Path(__file__).resolve().parent / "state.json"
        self._state = {
            "mode": "indoor",
            "mode_source": "manual",
            "auto_mode_setting": "manual",
            "mode_device_id": None,
            "mode_last_rssi": None,
            "mode_last_update_time": None,
            "mobile_device_token": None,
            "mobile_device_platform": "android",
            "mobile_device_id": None,
            "latest_reminder": None,
            "history": [],
        }
        self._load()

    def _load(self) -> None:
        if not self._file_path.exists():
            self._persist()
            return

        try:
            with self._file_path.open("r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    self._state.update(data)
        except (json.JSONDecodeError, OSError):
            self._persist()

    def _persist(self) -> None:
        with self._file_path.open("w", encoding="utf-8") as f:
            json.dump(self._state, f, indent=2)

    def get_mode(self) -> str:
        with self._lock:
            return self._state.get("mode", "indoor")

    def set_mode(self, mode: str) -> str:
        with self._lock:
            self._state["mode"] = mode
            self._persist()
            return mode

    def get_mode_state(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "mode": self._state.get("mode", "indoor"),
                "source": self._state.get("mode_source", "manual"),
                "autoModeSetting": self._state.get("auto_mode_setting", "manual"),
                "deviceId": self._state.get("mode_device_id"),
                "lastRssi": self._state.get("mode_last_rssi"),
                "lastUpdateTime": self._state.get("mode_last_update_time"),
            }

    def set_mode_state(self, state: Dict[str, Any]) -> Dict[str, Any]:
        with self._lock:
            self._state["mode"] = state.get("mode", self._state.get("mode", "indoor"))
            self._state["mode_source"] = state.get(
                "source",
                self._state.get("mode_source", "manual"),
            )
            self._state["auto_mode_setting"] = state.get(
                "autoModeSetting",
                self._state.get("auto_mode_setting", "manual"),
            )
            self._state["mode_device_id"] = state.get("deviceId")
            self._state["mode_last_rssi"] = state.get("lastRssi")
            self._state["mode_last_update_time"] = state.get("lastUpdateTime")
            self._persist()
            return {
                "mode": self._state.get("mode", "indoor"),
                "source": self._state.get("mode_source", "manual"),
                "autoModeSetting": self._state.get("auto_mode_setting", "manual"),
                "deviceId": self._state.get("mode_device_id"),
                "lastRssi": self._state.get("mode_last_rssi"),
                "lastUpdateTime": self._state.get("mode_last_update_time"),
            }

    def set_latest_reminder(self, reminder: Dict[str, Any]) -> None:
        with self._lock:
            self._state["latest_reminder"] = reminder
            history: List[Dict[str, Any]] = self._state.setdefault("history", [])
            history.append(reminder)
            self._persist()

    def set_mobile_device_token(
        self,
        token: str,
        platform: Optional[str] = None,
        device_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        with self._lock:
            self._state["mobile_device_token"] = token
            if platform is not None:
                self._state["mobile_device_platform"] = platform
            if device_id is not None:
                self._state["mobile_device_id"] = device_id
            self._persist()
            return {
                "token": self._state.get("mobile_device_token"),
                "platform": self._state.get("mobile_device_platform"),
                "device_id": self._state.get("mobile_device_id"),
            }

    def get_mobile_device_token(self) -> Optional[str]:
        with self._lock:
            return self._state.get("mobile_device_token")

    def get_latest_reminder(self) -> Optional[Dict[str, Any]]:
        with self._lock:
            return self._state.get("latest_reminder")

    def get_history(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self._state.get("history", []))

    def acknowledge(self, reminder_id: str, acknowledged_by: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            updated = None
            history: List[Dict[str, Any]] = self._state.get("history", [])
            for item in history:
                if item.get("id") == reminder_id:
                    item["status"] = "acknowledged"
                    item["acknowledgedBy"] = acknowledged_by
                    updated = item
            latest = self._state.get("latest_reminder")
            if latest and latest.get("id") == reminder_id:
                latest["status"] = "acknowledged"
                latest["acknowledgedBy"] = acknowledged_by
                updated = latest
            if updated:
                self._persist()
            return updated

    def mark_synced(self, reminder_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            updated = None
            history: List[Dict[str, Any]] = self._state.get("history", [])
            for item in history:
                if item.get("id") == reminder_id and item.get("status") == "acknowledged":
                    item["status"] = "synced"
                    updated = item
            latest = self._state.get("latest_reminder")
            if latest and latest.get("id") == reminder_id and latest.get("status") == "acknowledged":
                latest["status"] = "synced"
                updated = latest
            if updated:
                self._persist()
            return updated
