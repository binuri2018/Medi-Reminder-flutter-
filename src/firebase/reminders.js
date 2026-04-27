// src/firebase/reminders.js
import {
  collection,
  addDoc,
  updateDoc,
  deleteDoc,
  doc,
  query,
  orderBy,
  onSnapshot,
  Timestamp,
} from "firebase/firestore";
import { db } from "./config";

const COLLECTION = "reminders";

// ─────────────────────────────────────────
// Add Reminder
// ─────────────────────────────────────────
export const addReminder = async (reminder) => {
  const docRef = await addDoc(collection(db, COLLECTION), {
    ...reminder,
    repeatType: reminder.repeatType || "none", // "none" | "10min" | "daily" | "weekly" | "monthly"
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    completed: false,
    triggeredCount: 0,
  });

  return docRef.id;
};

// ─────────────────────────────────────────
// Update Reminder
// ─────────────────────────────────────────
export const updateReminder = async (id, data) => {
  const ref = doc(db, COLLECTION, id);

  await updateDoc(ref, {
    ...data,
    updatedAt: Timestamp.now(),
  });
};

// ─────────────────────────────────────────
// Delete Reminder
// ─────────────────────────────────────────
export const deleteReminder = async (id) => {
  await deleteDoc(doc(db, COLLECTION, id));
};

// ─────────────────────────────────────────
// Complete Reminder (Smart Recurring Logic)
// ─────────────────────────────────────────
export const completeReminder = async (reminder) => {
  const ref = doc(db, COLLECTION, reminder.id);

  // One-time reminder
  if (!reminder.repeatType || reminder.repeatType === "none") {
    await updateDoc(ref, {
      completed: true,
      updatedAt: Timestamp.now(),
      triggeredCount: (reminder.triggeredCount || 0) + 1,
    });
    return;
  }

  let nextDate = new Date(reminder.dueDate);
  const now = new Date();

  // 🔥 Move forward until future date
  while (nextDate <= now) {
    switch (reminder.repeatType) {
      case "60min":
        nextDate.setMinutes(nextDate.getMinutes() + 60);
        break;

      case "daily":
        nextDate.setDate(nextDate.getDate() + 1);
        break;

      case "weekly":
        nextDate.setDate(nextDate.getDate() + 7);
        break;

      case "monthly":
        nextDate.setMonth(nextDate.getMonth() + 1);
        break;

      default:
        break;
    }
  }

  await updateDoc(ref, {
    dueDate: Timestamp.fromDate(nextDate),
    updatedAt: Timestamp.now(),
    completed: false, // 🔥 Always active
    triggeredCount: (reminder.triggeredCount || 0) + 1,
  });
};

// ─────────────────────────────────────────
// Real-time Subscription
// ─────────────────────────────────────────
export const subscribeToReminders = (callback) => {
  const q = query(
    collection(db, COLLECTION),
    orderBy("createdAt", "desc")
  );

  return onSnapshot(q, (snapshot) => {
    const reminders = snapshot.docs.map((d) => {
      const data = d.data();
      return {
        id: d.id,
        ...data,
        dueDate: data.dueDate?.toDate
          ? data.dueDate.toDate()
          : new Date(data.dueDate),
      };
    });

    callback(reminders);
  });
};