import React from "react";

export default function DispatchStatus({ status }) {
  return (
    <div className="dispatch-status-card">
      <div className="dispatch-title">Dispatch Status</div>
      <div className="dispatch-row">
        <span>Mode:</span>
        <span className={`mode-badge ${status.mode}`}>{status.mode}</span>
      </div>
      <div className="dispatch-row">
        <span>Last Event:</span>
        <span>{status.lastEvent || "No dispatch yet"}</span>
      </div>
      <div className="dispatch-row">
        <span>Last Reminder:</span>
        <span>{status.lastReminderTitle || "-"}</span>
      </div>
      <div className="dispatch-row">
        <span>State:</span>
        <span>{status.state || "idle"}</span>
      </div>
    </div>
  );
}
