// src/components/ReminderCard.jsx
import React from 'react';
import { format, isPast, isToday, isTomorrow } from 'date-fns';
import { updateReminder, deleteReminder } from '../firebase/reminders';
import { speakReminder } from '../hooks/useVoice';
import toast from 'react-hot-toast';

const PRIORITY_COLORS = { high: '#e94560', medium: '#f5a623', low: '#4ecdc4' };
const CATEGORY_ICONS = { Work: '💼', Health: '❤️', Personal: '👤', Shopping: '🛒', Finance: '💰', Fitness: '🏃', General: '📌' };

function formatDue(date) {
  if (isToday(date)) return `Today ${format(date, 'h:mm a')}`;
  if (isTomorrow(date)) return `Tomorrow ${format(date, 'h:mm a')}`;
  return format(date, 'MMM d, yyyy h:mm a');
}

export default function ReminderCard({ reminder, onEdit }) {
  const due = reminder.dueDate instanceof Date ? reminder.dueDate : new Date(reminder.dueDate);
  const overdue = isPast(due) && !reminder.completed;

  const toggleComplete = async () => {
    await updateReminder(reminder.id, { completed: !reminder.completed });
    if (!reminder.completed) {
      speakReminder(`Reminder "${reminder.title}" marked as complete. Great job!`);
    }
  };

  const handleDelete = async () => {
    if (window.confirm('Delete this reminder?')) {
      await deleteReminder(reminder.id);
      toast.success('Reminder deleted');
    }
  };

  const handleSpeak = () => {
    // Only include description if it exists
    const desc = reminder.description ? ` Details: ${reminder.description}.` : '';
    const msg = `Reminder for ${reminder.category}. Title: ${reminder.title}.${desc} Due ${formatDue(due)}. Priority: ${reminder.priority}.`;
    speakReminder(msg);
  };

  return (
    <div
      className={`reminder-card ${reminder.completed ? 'completed' : ''} ${overdue ? 'overdue' : ''}`}
      style={{ borderLeft: `4px solid ${PRIORITY_COLORS[reminder.priority] || '#888'}` }}
    >
      <div className="card-top">
        <button className="complete-btn" onClick={toggleComplete} title="Toggle complete">
          {reminder.completed ? '✅' : '⭕'}
        </button>
        <div className="card-main">
          <div className="card-title">{reminder.title}</div>
          {reminder.description && <div className="card-desc">{reminder.description}</div>}
          <div className="card-meta">
            <span className="category-badge">
              {CATEGORY_ICONS[reminder.category] || '📌'} {reminder.category}
            </span>
            <span className={`due-badge ${overdue ? 'overdue-text' : ''}`}>
              🕐 {formatDue(due)}
              {overdue && ' (Overdue)'}
            </span>
            {reminder.repeat !== 'none' && <span className="repeat-badge">🔁 {reminder.repeat}</span>}
          </div>
        </div>
        <div className="card-actions">
          <button onClick={handleSpeak} title="Speak reminder" className="icon-btn speak">🔊</button>
          <button onClick={() => onEdit(reminder)} title="Edit" className="icon-btn edit">✏️</button>
          <button onClick={handleDelete} title="Delete" className="icon-btn delete">🗑️</button>
        </div>
      </div>
    </div>
  );
}