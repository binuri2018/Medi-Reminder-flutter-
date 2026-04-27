// src/hooks/useReminderChecker.js
import { useEffect, useRef } from "react";
import { speakReminder } from "./useVoice";
import { updateReminder, completeReminder } from "../firebase/reminders";
import { sendReminderToBackend } from "../services/reminderDispatchApi";
import toast from "react-hot-toast";

const recentlyHandledAt = new Map();
const RECENTLY_HANDLED_WINDOW_MS = 120000;

// ─────────────────────────────────────────
// Mark Done (Supports Repeat)
// ─────────────────────────────────────────
const markDone = async (reminder, toastId) => {
  recentlyHandledAt.set(reminder.id, Date.now());

  if (reminder.repeatType && reminder.repeatType !== "none") {
    await completeReminder(reminder);
    speakReminder(`Great! ${reminder.title} scheduled again.`);
  } else {
    await updateReminder(reminder.id, { completed: true });
    speakReminder(`Got it! ${reminder.title} marked as done.`);
  }

  // Force close active side notification immediately.
  toast.dismiss();
  toast.dismiss(toastId);
  toast.success("✅ Reminder handled!", { duration: 3000 });
};

// ─────────────────────────────────────────
// Voice Listener
// ─────────────────────────────────────────
const DONE_WORDS = [
  "done", "complete", "completed", "finish", "finished",
  "ok", "okay", "yes", "got it", "understood", "marked",
  "dun", "don", "doan", "doone",
];

const listenForDoneCommand = (reminder, getToastId, micStopRef) => {
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SR) {
    toast.error("Speech recognition not supported. Use the Mark as Done button.");
    return;
  }

  const recognition = new SR();
  recognition.lang = "en-US";
  recognition.continuous = true;
  recognition.interimResults = true;

  let marked = false;
  let promptShown = false;
  let mainTimeoutCleared = false;
  let micErrorShown = false;
  let shouldAutoRestart = true;

  const doMarkDone = () => {
    if (marked) return;
    marked = true;
    try { recognition.stop(); } catch {}
    if (micStopRef.current) micStopRef.current = null;
    markDone(reminder, getToastId());
  };

  const isDoneWord = (said) => {
    const s = said.toLowerCase().trim();
    return DONE_WORDS.some((w) => s.includes(w));
  };

  recognition.onresult = (e) => {
    for (let i = 0; i < e.results.length; i++) {
      const result = e.results[i];
      const said = (result[0]?.transcript || "").trim();
      if (!said) continue;
      if (isDoneWord(said)) {
        doMarkDone();
        return;
      }
      // User spoke but didn't say "done" - prompt to try again
      if (!promptShown && said.length > 2) {
        promptShown = true;
        toast("Say \"done\" to complete", { duration: 2500, icon: "🎤" });
      }
    }
  };

  recognition.onerror = (e) => {
    if (e.error === "no-speech") return;
    if (e.error === "aborted") return;
    if (e.error === "not-allowed" || e.error === "service-not-allowed") {
      shouldAutoRestart = false;
      if (!micErrorShown) {
        micErrorShown = true;
        toast.error("Mic needs a click to start. Use the Mark as Done button.", { duration: 4000 });
      }
      return;
    }

    // Avoid spamming repeated identical mic error toasts while recognition auto-restarts.
    if (!micErrorShown) {
      micErrorShown = true;
      toast.error("Mic error. Use the Mark as Done button.");
    }
  };

  const LISTEN_DURATION_MS = 90000; // 90 seconds - user can keep trying
  const mainTimeout = setTimeout(() => {
    try { recognition.stop(); } catch {}
    if (!marked) toast.error("Listening ended. Use the Mark as Done button.");
  }, LISTEN_DURATION_MS);

  recognition.onend = () => {
    if (marked) return;
    if (mainTimeoutCleared) return;
    if (!shouldAutoRestart) return;
    try {
      recognition.start(); // Restart - keep listening so user can say "done" again
    } catch {}
  };

  micStopRef.current = () => {
    mainTimeoutCleared = true;
    clearTimeout(mainTimeout);
    try { recognition.stop(); } catch {}
  };

  try {
    recognition.start();
    toast.success("Listening... Say \"done\" when finished", { duration: 3000 });
  } catch {
    toast.error("Could not start mic. Use the Mark as Done button.");
  }
};

// ─────────────────────────────────────────
// MAIN CHECKER
// ─────────────────────────────────────────
export const useReminderChecker = (reminders, mode, onDispatchStatus) => {
  const notifiedRef = useRef(new Set());

  useEffect(() => {
    const check = async () => {
      const now = new Date();

      for (const reminder of reminders) {
        const handledAt = recentlyHandledAt.get(reminder.id);
        if (handledAt && Date.now() - handledAt < RECENTLY_HANDLED_WINDOW_MS) {
          continue;
        }
        if (handledAt && Date.now() - handledAt >= RECENTLY_HANDLED_WINDOW_MS) {
          recentlyHandledAt.delete(reminder.id);
        }

        if (reminder.completed) continue;

        const due = reminder.dueDate instanceof Date ? reminder.dueDate : new Date(reminder.dueDate);
        const diff = due - now;

        // Auto-fix overdue repeating reminders
        if (reminder.repeatType && reminder.repeatType !== "none" && diff < -60000) {
          await completeReminder(reminder);
          continue;
        }

        // Trigger reminder
        if (diff <= 0 && diff > -300000) {
          if (notifiedRef.current.has(reminder.id)) continue;
          notifiedRef.current.add(reminder.id);

          const desc = reminder.description ? ` Description: ${reminder.description}.` : '';
          const micStopRef = { current: null };
          const toastId = `reminder-${reminder.id}`;
          const activeToastIdRef = { current: toastId };

          if (mode === "outdoor") {
            try {
              onDispatchStatus?.({
                mode,
                lastEvent: "Sending reminder to mobile endpoint",
                lastReminderTitle: reminder.title,
                state: "sending",
              });
              await sendReminderToBackend(reminder);
              toast.success(`📱 Sent to mobile: ${reminder.title}`);
              onDispatchStatus?.({
                mode,
                lastEvent: "Reminder dispatched to outdoor client",
                lastReminderTitle: reminder.title,
                state: "success",
              });
            } catch {
              toast.error("Outdoor dispatch failed. Reminder stays in web app flow.");
              onDispatchStatus?.({
                mode,
                lastEvent: "Outdoor dispatch failed",
                lastReminderTitle: reminder.title,
                state: "error",
              });
            }
          } else {
            // Start mic in parallel with reminder - user can say "done" while it plays
            const spoke = speakReminder(
              `Reminder: ${reminder.title}.${desc} Say done or tap the Done button.`,
              {
                onError: () => {
                  toast.error("Speaker alert failed. Use the Mark as Done button.");
                },
              }
            );
            if (!spoke) {
              toast.error("Speaker unavailable in this browser. Use the Mark as Done button.");
            }
            listenForDoneCommand(reminder, () => activeToastIdRef.current, micStopRef);

            const createdToastId = toast.custom(
              (t) => (
                <div style={{
                  background: "#1a1a2e",
                  color: "#fff",
                  padding: "16px",
                  borderRadius: "12px",
                  minWidth: "280px",
                }}>
                  <div style={{ fontWeight: 700, marginBottom: "10px" }}>
                    ⏰ {reminder.title}
                  </div>
                  {reminder.description && (
                    <div style={{ fontSize: "14px", opacity: 0.9, marginBottom: "10px" }}>
                      {reminder.description}
                    </div>
                  )}
                  <button
                    onClick={() => {
                      if (micStopRef.current) micStopRef.current();
                      markDone(reminder, t.id);
                    }}
                    style={{
                      background: "#4ecdc4",
                      border: "none",
                      padding: "10px",
                      width: "100%",
                      borderRadius: "8px",
                      fontWeight: 600,
                      cursor: "pointer",
                      color: "#1a1a2e",
                    }}
                  >
                    ✅ Mark as Done
                  </button>
                </div>
              ),
              { duration: 30000, id: toastId }
            );
            activeToastIdRef.current = createdToastId || toastId;
            onDispatchStatus?.({
              mode: "indoor",
              lastEvent: "Reminder shown in web UI with voice prompt",
              lastReminderTitle: reminder.title,
              state: "success",
            });
          }

          await updateReminder(reminder.id, { triggeredCount: (reminder.triggeredCount || 0) + 1 });
        }
      }
    };

    const interval = setInterval(check, 5000);
    return () => clearInterval(interval);
  }, [mode, onDispatchStatus, reminders]);
};