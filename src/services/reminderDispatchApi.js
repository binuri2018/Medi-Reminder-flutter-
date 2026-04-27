const BACKEND_URL = process.env.REACT_APP_BACKEND_URL || "http://127.0.0.1:8000";

export const sendReminderToBackend = async (reminder) => {
  const dueTimeIso = reminder?.dueDate
    ? new Date(reminder.dueDate).toISOString()
    : new Date().toISOString();
  const payload = {
    id: reminder.id,
    title: reminder.title,
    message: reminder.description || "",
    timestamp: dueTimeIso,
  };

  const res = await fetch(`${BACKEND_URL}/api/reminders/send`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    throw new Error("Failed to dispatch reminder");
  }

  return res.json();
};

export const fetchReminderHistory = async () => {
  const res = await fetch(`${BACKEND_URL}/api/reminders/history`);
  if (!res.ok) {
    throw new Error("Failed to fetch reminder history");
  }
  return res.json();
};

export const markReminderSynced = async (reminderId) => {
  const res = await fetch(`${BACKEND_URL}/api/reminders/${reminderId}/sync`, {
    method: "POST",
  });
  if (res.status === 404) {
    // Idempotent behavior: treat missing/previously synced reminder as completed.
    return { alreadySynced: true };
  }
  if (!res.ok) {
    throw new Error("Failed to mark reminder as synced");
  }
  return res.json();
};
