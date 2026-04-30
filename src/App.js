// src/App.js
import React, { useState, useEffect, useRef } from "react";
import { BrowserRouter, Routes, Route, NavLink } from "react-router-dom";
import { Toaster } from "react-hot-toast";
import { subscribeToReminders } from "./firebase/reminders";
import { useReminderChecker } from "./hooks/useReminderChecker";
import { useOutdoorAckSync } from "./hooks/useOutdoorAckSync";
import Reminders from "./pages/Reminders";
import Analytics from "./pages/Analytics";
import { getMode, setMode } from "./services/modeApi";
import "./App.css";

function Layout({
  reminders,
  mode,
  dispatchStatus,
  onDispatchStatus,
}) {
  useReminderChecker(reminders, mode, onDispatchStatus);
  useOutdoorAckSync(reminders, onDispatchStatus);
  const overdue = reminders.filter(r => !r.completed && new Date(r.dueDate) < new Date()).length;
  const upcoming = reminders.filter(r => !r.completed && new Date(r.dueDate) >= new Date()).length;

  return (
    <div className="app">
      <nav className="sidebar">
        <div className="brand">
          <div className="brand-icon">⏰</div>
          <div>
            <div className="brand-name">RemindAI</div>
            <div className="brand-sub">Smart Reminders</div>
          </div>
        </div>

        <div className="nav-stats">
          <div className="stat-pill"><span>📋</span><span>{reminders.length}</span></div>
          <div className="stat-pill overdue"><span>⚠️</span><span>{overdue}</span></div>
          <div className="stat-pill upcoming"><span>🔮</span><span>{upcoming}</span></div>
        </div>

        <div className="nav-links">
          <NavLink to="/" className={({isActive}) => `nav-link ${isActive ? 'active' : ''}`} end>
            <span>🔔</span> Reminders
          </NavLink>
          <NavLink to="/analytics" className={({isActive}) => `nav-link ${isActive ? 'active' : ''}`}>
            <span>📊</span> Analytics
          </NavLink>
        </div>

        <div className="sidebar-footer">
          <div className="voice-info">
            <span>🎤</span>
            <span>Voice input supported</span>
          </div>
          <div className="voice-info">
            <span>🔊</span>
            <span>Speaker alerts active</span>
          </div>
        </div>
      </nav>

      <main className="main-content">
        <Routes>
          <Route
            path="/"
            element={
              <Reminders
                reminders={reminders}
                mode={mode}
                modeSource={dispatchStatus.source}
                autoModeSetting={dispatchStatus.autoModeSetting}
                lastRssi={dispatchStatus.lastRssi}
                dispatchStatus={dispatchStatus}
              />
            }
          />
          <Route path="/analytics" element={<Analytics reminders={reminders} />} />
        </Routes>
      </main>
    </div>
  );
}

/** Poll `/api/mode` this often so indoor/outdoor (driven only by mobile BLE) mirrors quickly on web */
const MODE_POLL_MS = 5000;

export default function App() {
  const [reminders, setReminders] = useState([]);
  const [mode, setModeState] = useState("indoor");
  const migratedAutoRef = useRef(false);

  const [dispatchStatus, setDispatchStatus] = useState({
    mode: "indoor",
    source: "bluetooth_auto",
    autoModeSetting: "bluetooth_auto",
    lastRssi: null,
    lastEvent: "",
    lastReminderTitle: "",
    state: "idle",
  });

  useEffect(() => {
    const unsub = subscribeToReminders(setReminders);
    return () => unsub();
  }, []);

  useEffect(() => {
    const loadMode = async () => {
      try {
        let data = await getMode();

        if (!migratedAutoRef.current) {
          if (
            (data.autoModeSetting || "").toLowerCase() !== "bluetooth_auto"
          ) {
            try {
              data = await setMode({
                mode: data.mode || "indoor",
                source: "bluetooth_auto",
                autoModeSetting: "bluetooth_auto",
                reason: "BLE beacon mode is mobile-led; unify auto setting",
              });
            } catch (_) {}
          }
          migratedAutoRef.current = true;
        }

        setModeState(data.mode);
        setDispatchStatus((prev) => ({
          ...prev,
          mode: data.mode,
          source: data.source || "bluetooth_auto",
          autoModeSetting: data.autoModeSetting || "bluetooth_auto",
          lastRssi: typeof data.lastRssi === "number" ? data.lastRssi : null,
        }));
      } catch {
        // indoor fallback mode if offline
      }
    };
    loadMode();
    const poll = setInterval(loadMode, MODE_POLL_MS);
    return () => clearInterval(poll);
  }, []);

  return (
    <BrowserRouter>
      <Toaster position="top-right" toastOptions={{ duration: 4000 }} />
      <Layout
        reminders={reminders}
        mode={mode}
        dispatchStatus={dispatchStatus}
        onDispatchStatus={setDispatchStatus}
      />
    </BrowserRouter>
  );
}
