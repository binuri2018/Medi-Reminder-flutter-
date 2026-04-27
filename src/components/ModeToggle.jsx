import React from "react";

export default function ModeToggle({
  mode,
  source,
  autoModeSetting,
  lastRssi,
  onChangeMode,
  onAutoModeSettingChange,
  saving,
}) {
  const sourceLabel = source === "bluetooth_auto" ? "Bluetooth auto" : "Manual";
  const autoEnabled = autoModeSetting === "bluetooth_auto";

  return (
    <div className="mode-toggle-card">
      <div className="mode-toggle-header">
        <h3>Indoor-Outdoor Simulation</h3>
        <span className={`mode-badge ${mode}`}>Current: {mode}</span>
      </div>
      <div className="mode-meta-row">
        <span>Source: {sourceLabel}</span>
        <span>Auto mode: {autoEnabled ? "Enabled" : "Manual only"}</span>
        <span>Last RSSI: {typeof lastRssi === "number" ? `${lastRssi} dBm` : "N/A"}</span>
      </div>
      <div className="mode-toggle-actions">
        <button
          className={`btn-secondary ${mode === "indoor" ? "active-mode" : ""}`}
          onClick={() => onChangeMode("indoor")}
          disabled={saving}
        >
          Indoor Mode
        </button>
        <button
          className={`btn-secondary ${mode === "outdoor" ? "active-mode" : ""}`}
          onClick={() => onChangeMode("outdoor")}
          disabled={saving}
        >
          Outdoor Mode
        </button>
      </div>
      <div className="mode-toggle-actions">
        <button
          className={`btn-secondary ${autoEnabled ? "active-mode" : ""}`}
          onClick={() =>
            onAutoModeSettingChange(autoEnabled ? "manual" : "bluetooth_auto")
          }
          disabled={saving}
        >
          {autoEnabled ? "Disable Bluetooth Auto Mode" : "Enable Bluetooth Auto Mode"}
        </button>
      </div>
    </div>
  );
}
