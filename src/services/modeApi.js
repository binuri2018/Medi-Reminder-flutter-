const BACKEND_URL = process.env.REACT_APP_BACKEND_URL || "http://127.0.0.1:8000";

export const getMode = async () => {
  const res = await fetch(`${BACKEND_URL}/api/mode`);
  if (!res.ok) {
    throw new Error("Failed to load mode");
  }
  return res.json();
};

export const setMode = async ({ mode, source = "manual", autoModeSetting, deviceId, rssi, reason }) => {
  const payload = {
    mode,
    source,
    timestamp: new Date().toISOString(),
  };
  if (autoModeSetting) payload.autoModeSetting = autoModeSetting;
  if (deviceId) payload.deviceId = deviceId;
  if (typeof rssi === "number") payload.rssi = rssi;
  if (reason) payload.reason = reason;
  const res = await fetch(`${BACKEND_URL}/api/mode`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    throw new Error("Failed to update mode");
  }
  return res.json();
};
