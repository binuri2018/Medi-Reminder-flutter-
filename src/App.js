// src/App.js
import React, { useState, useEffect } from 'react';
import { BrowserRouter, Routes, Route, NavLink } from 'react-router-dom';
import { Toaster } from 'react-hot-toast';
import { subscribeToReminders } from './firebase/reminders';
import { useReminderChecker } from './hooks/useReminderChecker';
import { useOutdoorAckSync } from './hooks/useOutdoorAckSync';
import Reminders from './pages/Reminders';
import Analytics from './pages/Analytics';
import { getMode, setMode } from './services/modeApi';
import './App.css';

function Layout({
  reminders,
  mode,
  onModeChange,
  onAutoModeSettingChange,
  modeSaving,
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
                onModeChange={onModeChange}
                onAutoModeSettingChange={onAutoModeSettingChange}
                modeSaving={modeSaving}
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

export default function App() {
  const [reminders, setReminders] = useState([]);
  const [mode, setModeState] = useState('indoor');
  const [modeSaving, setModeSaving] = useState(false);
  const [dispatchStatus, setDispatchStatus] = useState({
    mode: 'indoor',
    source: 'manual',
    autoModeSetting: 'manual',
    lastRssi: null,
    lastEvent: '',
    lastReminderTitle: '',
    state: 'idle',
  });

  useEffect(() => {
    const unsub = subscribeToReminders(setReminders);
    return () => unsub();
  }, []);

  useEffect(() => {
    const loadMode = async () => {
      try {
        const data = await getMode();
        setModeState(data.mode);
        setDispatchStatus((prev) => ({
          ...prev,
          mode: data.mode,
          source: data.source || 'manual',
          autoModeSetting: data.autoModeSetting || 'manual',
          lastRssi: typeof data.lastRssi === 'number' ? data.lastRssi : null,
        }));
      } catch {
        // Keep indoor fallback mode if backend is not reachable.
      }
    };
    loadMode();
    const poll = setInterval(loadMode, 10000);
    return () => clearInterval(poll);
  }, []);

  const handleModeChange = async (newMode) => {
    setModeSaving(true);
    try {
      const data = await setMode({
        mode: newMode,
        source: 'manual',
        reason: 'Manual mode switch from web app',
      });
      setModeState(data.mode);
      setDispatchStatus((prev) => ({
        ...prev,
        mode: data.mode,
        source: data.source || 'manual',
        autoModeSetting: data.autoModeSetting || prev.autoModeSetting,
        lastRssi: typeof data.lastRssi === 'number' ? data.lastRssi : prev.lastRssi,
        lastEvent: `Mode changed to ${data.mode}`,
        state: 'success',
      }));
    } catch {
      setDispatchStatus((prev) => ({
        ...prev,
        lastEvent: 'Failed to change mode (backend unavailable)',
        state: 'error',
      }));
    } finally {
      setModeSaving(false);
    }
  };

  const handleAutoModeSettingChange = async (newSetting) => {
    setModeSaving(true);
    try {
      const data = await setMode({
        mode,
        source: 'manual',
        autoModeSetting: newSetting,
        reason: 'Auto mode setting changed from web app',
      });
      setModeState(data.mode);
      setDispatchStatus((prev) => ({
        ...prev,
        mode: data.mode,
        source: data.source || prev.source,
        autoModeSetting: data.autoModeSetting || newSetting,
        lastEvent:
          newSetting === 'bluetooth_auto'
            ? 'Bluetooth auto mode enabled'
            : 'Manual-only mode enabled',
        state: 'success',
      }));
    } catch {
      setDispatchStatus((prev) => ({
        ...prev,
        lastEvent: 'Failed to update auto mode setting',
        state: 'error',
      }));
    } finally {
      setModeSaving(false);
    }
  };

  return (
    <BrowserRouter>
      <Toaster position="top-right" toastOptions={{ duration: 4000 }} />
      <Layout
        reminders={reminders}
        mode={mode}
        onModeChange={handleModeChange}
        onAutoModeSettingChange={handleAutoModeSettingChange}
        modeSaving={modeSaving}
        dispatchStatus={dispatchStatus}
        onDispatchStatus={setDispatchStatus}
      />
    </BrowserRouter>
  );
}
