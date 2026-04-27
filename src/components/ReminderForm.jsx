// src/components/ReminderForm.jsx
import React, { useState, useEffect } from 'react';
import { useVoiceInput, parseVoiceCommand } from '../hooks/useVoice';
import { addReminder, updateReminder } from '../firebase/reminders';
import toast from 'react-hot-toast';

const CATEGORIES = ['General', 'Work', 'Health', 'Personal', 'Shopping', 'Finance', 'Fitness'];
const PRIORITIES = ['low', 'medium', 'high'];

const defaultForm = {
  title: '',
  description: '',
  dueDate: '',
  dueTime: '',
  category: 'General',
  priority: 'medium',
  repeatType: 'none',   // ✅ FIXED (was repeat)
};

export default function ReminderForm({ onClose, editData }) {
  const [form, setForm] = useState(defaultForm);
  const [loading, setLoading] = useState(false);
  const { isListening, transcript, startListening, stopListening, reset } = useVoiceInput();

  // ─────────────────────────────────────────
  // Load Edit Data
  // ─────────────────────────────────────────
  useEffect(() => {
    if (editData) {
      const d = editData.dueDate instanceof Date
        ? editData.dueDate
        : new Date(editData.dueDate);

      setForm({
        title: editData.title || '',
        description: editData.description || '',
        dueDate: d.toISOString().split('T')[0],
        dueTime: d.toTimeString().slice(0, 5),
        category: editData.category || 'General',
        priority: editData.priority || 'medium',
        repeatType: editData.repeatType || 'none', // ✅ FIXED
      });
    }
  }, [editData]);

  // ─────────────────────────────────────────
  // Voice Auto Fill
  // ─────────────────────────────────────────
  useEffect(() => {
    if (transcript && !isListening) {
      const parsed = parseVoiceCommand(transcript);
      setForm(f => ({
        ...f,
        title: parsed.title,
        dueDate: parsed.dueDate.toISOString().split('T')[0],
        dueTime: parsed.dueDate.toTimeString().slice(0, 5),
        priority: parsed.priority,
        category: parsed.category,
      }));
    }
  }, [transcript, isListening]);

  // ─────────────────────────────────────────
  // Submit
  // ─────────────────────────────────────────
  const handleSubmit = async (e) => {
    e.preventDefault();

    if (!form.title || !form.dueDate) {
      return toast.error('Title and date are required');
    }

    setLoading(true);

    try {
      const dueDate = new Date(`${form.dueDate}T${form.dueTime || '09:00'}`);

      const payload = {
        title: form.title,
        description: form.description,
        dueDate,
        category: form.category,
        priority: form.priority,
        repeatType: form.repeatType, // ✅ Correct field
      };

      if (editData) {
        await updateReminder(editData.id, payload);
        toast.success('Reminder updated!');
      } else {
        await addReminder(payload);
        toast.success('Reminder created!');
      }

      onClose();

    } catch (err) {
      toast.error('Failed to save reminder');
    }

    setLoading(false);
  };

  // ─────────────────────────────────────────
  // UI
  // ─────────────────────────────────────────
  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal-card" onClick={e => e.stopPropagation()}>
        <div className="modal-header">
          <h2>{editData ? '✏️ Edit Reminder' : '➕ New Reminder'}</h2>
          <button className="close-btn" onClick={onClose}>✕</button>
        </div>

        {/* Voice Input */}
        <div className="voice-section">
          <button
            type="button"
            className={`voice-btn ${isListening ? 'listening' : ''}`}
            onClick={isListening ? stopListening : startListening}
          >
            {isListening ? '🔴 Listening...' : '🎤 Add by Voice'}
          </button>

          {transcript && (
            <div className="transcript">
              <span>Heard: "{transcript}"</span>
              <button onClick={reset}>✕</button>
            </div>
          )}
        </div>

        <form onSubmit={handleSubmit} className="reminder-form">

          <div className="form-group">
            <label>Title *</label>
            <input
              value={form.title}
              onChange={e => setForm({...form, title: e.target.value})}
              placeholder="What do you need to remember?"
              required
            />
          </div>

          <div className="form-group">
            <label>Description</label>
            <textarea
              value={form.description}
              onChange={e => setForm({...form, description: e.target.value})}
              placeholder="Additional details..."
              rows={2}
            />
          </div>

          <div className="form-row">
            <div className="form-group">
              <label>Date *</label>
              <input
                type="date"
                value={form.dueDate}
                onChange={e => setForm({...form, dueDate: e.target.value})}
                required
              />
            </div>

            <div className="form-group">
              <label>Time</label>
              <input
                type="time"
                value={form.dueTime}
                onChange={e => setForm({...form, dueTime: e.target.value})}
              />
            </div>
          </div>

          <div className="form-row">
            <div className="form-group">
              <label>Category</label>
              <select
                value={form.category}
                onChange={e => setForm({...form, category: e.target.value})}
              >
                {CATEGORIES.map(c => (
                  <option key={c}>{c}</option>
                ))}
              </select>
            </div>

            <div className="form-group">
              <label>Priority</label>
              <select
                value={form.priority}
                onChange={e => setForm({...form, priority: e.target.value})}
              >
                {PRIORITIES.map(p => (
                  <option key={p} value={p}>
                    {p.charAt(0).toUpperCase() + p.slice(1)}
                  </option>
                ))}
              </select>
            </div>
          </div>

          {/* ✅ UPDATED REPEAT FIELD */}
          <div className="form-group">
            <label>Repeat</label>
            <select
              value={form.repeatType}
              onChange={e => setForm({...form, repeatType: e.target.value})}
            >
              <option value="none">No Repeat</option>
              <option value="60min">Hourly</option>
              <option value="daily">Daily</option>
              <option value="weekly">Weekly</option>
              <option value="monthly">Monthly</option>
            </select>
          </div>

          <div className="form-actions">
            <button type="button" className="btn-secondary" onClick={onClose}>
              Cancel
            </button>

            <button type="submit" className="btn-primary" disabled={loading}>
              {loading ? 'Saving...' : editData ? 'Update' : 'Create Reminder'}
            </button>
          </div>

        </form>
      </div>
    </div>
  );
}