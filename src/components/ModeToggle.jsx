import React from "react";
import { TARGET_BEACON_NAME } from "../ble/beaconConstants";

export default function ModeToggle({
  mode,
  source,
  autoModeSetting,
  lastRssi,
}) {
  const bleAuto =
    (autoModeSetting || "").trim().toLowerCase() === "bluetooth_auto";
  const srcLabel =
    source === "bluetooth_auto"
      ? "Mobile BLE (RSSI-driven)"
      : source || "unknown";

  return (
    <div className="mode-toggle-card">
      <div className="mode-toggle-header">
        <h3>Indoor / Outdoor</h3>
        <span className={`mode-badge ${mode}`}>Current: {mode}</span>
      </div>
      <p className="mode-ble-explainer">
        This dashboard does <strong>not</strong> scan Bluetooth. Indoor/outdoor{" "}
        comes from your <strong>mobile app only</strong>, via the advertiser{" "}
        <strong>{TARGET_BEACON_NAME}</strong>: good signal stays or returns
        indoor; weaker signal or losing the beacon shifts to outdoor. The backend
        state here updates every few seconds so the web stays in sync.
      </p>
      <div className="mode-meta-row">
        <span>Backend source: {srcLabel}</span>
        <span>Auto: {bleAuto ? "Mobile beacon RSSI" : autoModeSetting}</span>
        <span>
          Last RSSI (from phone→server):{" "}
          {typeof lastRssi === "number" ? `${lastRssi} dBm` : "N/A"}
        </span>
      </div>
    </div>
  );
}
