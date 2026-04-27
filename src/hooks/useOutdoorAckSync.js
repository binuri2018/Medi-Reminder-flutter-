import { useEffect, useRef } from "react";
import toast from "react-hot-toast";

import { completeReminder, updateReminder } from "../firebase/reminders";
import { fetchReminderHistory, markReminderSynced } from "../services/reminderDispatchApi";

const applyAckToFirebase = async (reminder) => {
  if (reminder.repeatType && reminder.repeatType !== "none") {
    await completeReminder(reminder);
    return;
  }
  await updateReminder(reminder.id, { completed: true });
};

export const useOutdoorAckSync = (reminders, onDispatchStatus) => {
  const syncingRef = useRef(new Set());

  useEffect(() => {
    const syncAcknowledgedReminders = async () => {
      try {
        const data = await fetchReminderHistory();
        const history = data?.data || [];
        const acknowledged = history.filter((item) => item.status === "acknowledged");

        for (const item of acknowledged) {
          if (!item?.id || syncingRef.current.has(item.id)) continue;
          syncingRef.current.add(item.id);

          const reminder = reminders.find((r) => r.id === item.id);

          try {
            if (reminder) {
              await applyAckToFirebase(reminder);
              toast.success(`✅ Synced mobile completion: ${reminder.title}`);
              onDispatchStatus?.((prev) => ({
                ...prev,
                lastEvent: "Mobile acknowledgment synced to Firebase",
                lastReminderTitle: reminder.title,
                state: "success",
              }));
            }
            const syncResult = await markReminderSynced(item.id);
            if (!syncResult?.alreadySynced && reminder) {
              onDispatchStatus?.((prev) => ({
                ...prev,
                lastEvent: "Mobile acknowledgment synced to Firebase",
                lastReminderTitle: reminder.title,
                state: "success",
              }));
            }
          } catch {
            onDispatchStatus?.((prev) => ({
              ...prev,
              lastEvent: "Failed to sync mobile acknowledgment",
              lastReminderTitle: reminder?.title || item.id,
              state: "error",
            }));
          } finally {
            syncingRef.current.delete(item.id);
          }
        }
      } catch {
        // Backend unavailable; keep retry loop alive.
      }
    };

    const interval = setInterval(syncAcknowledgedReminders, 5000);
    return () => clearInterval(interval);
  }, [onDispatchStatus, reminders]);
};
