// src/pages/Reminders.jsx
import React, { useState } from 'react';
import ReminderCard from '../components/ReminderCard';
import ReminderForm from '../components/ReminderForm';
import ModeToggle from '../components/ModeToggle';
import DispatchStatus from '../components/DispatchStatus';

const FILTERS = ['All', 'Today', 'Upcoming', 'Completed', 'Overdue'];
const CATEGORIES = ['All', 'Work', 'Health', 'Personal', 'Shopping', 'Finance', 'Fitness', 'General'];

export default function Reminders({
  reminders,
  mode,
  modeSource,
  autoModeSetting,
  lastRssi,
  dispatchStatus,
}) {
  const [showForm, setShowForm] = useState(false);
  const [editData, setEditData] = useState(null);
  const [filter, setFilter] = useState('All');
  const [catFilter, setCatFilter] = useState('All');
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('dueDate');

  const now = new Date();
  const today = new Date(); today.setHours(23,59,59,999);
  const todayStart = new Date(); todayStart.setHours(0,0,0,0);

  const filtered = reminders
    .filter(r => {
      const due = r.dueDate instanceof Date ? r.dueDate : new Date(r.dueDate);
      if (filter === 'Today') return due >= todayStart && due <= today && !r.completed;
      if (filter === 'Upcoming') return due > now && !r.completed;
      if (filter === 'Completed') return r.completed;
      if (filter === 'Overdue') return due < now && !r.completed;
      return true;
    })
    .filter(r => catFilter === 'All' || r.category === catFilter)
    .filter(r => !search || r.title.toLowerCase().includes(search.toLowerCase()))
    .sort((a, b) => {
      if (sortBy === 'dueDate') return new Date(a.dueDate) - new Date(b.dueDate);
      if (sortBy === 'priority') {
        const p = { high: 0, medium: 1, low: 2 };
        return p[a.priority] - p[b.priority];
      }
      if (sortBy === 'title') return a.title.localeCompare(b.title);
      return 0;
    });

  const handleEdit = (reminder) => { setEditData(reminder); setShowForm(true); };
  const handleClose = () => { setShowForm(false); setEditData(null); };

  return (
    <div className="reminders-page">
      <div className="page-header">
        <h1 className="page-title">⏰ My Reminders</h1>
        <button className="btn-primary add-btn" onClick={() => setShowForm(true)}>
          + New Reminder
        </button>
      </div>

      {/* Search & Sort */}
      <ModeToggle
        mode={mode}
        source={modeSource}
        autoModeSetting={autoModeSetting}
        lastRssi={lastRssi}
      />
      <DispatchStatus status={dispatchStatus} />

      <div className="toolbar">
        <input className="search-input" placeholder="🔍 Search reminders..."
          value={search} onChange={e => setSearch(e.target.value)} />
        <select className="sort-select" value={sortBy} onChange={e => setSortBy(e.target.value)}>
          <option value="dueDate">Sort: Due Date</option>
          <option value="priority">Sort: Priority</option>
          <option value="title">Sort: Title</option>
        </select>
      </div>

      {/* Filters */}
      <div className="filter-tabs">
        {FILTERS.map(f => (
          <button key={f} className={`filter-tab ${filter === f ? 'active' : ''}`}
            onClick={() => setFilter(f)}>{f}</button>
        ))}
      </div>
      <div className="cat-filters">
        {CATEGORIES.map(c => (
          <button key={c} className={`cat-chip ${catFilter === c ? 'active' : ''}`}
            onClick={() => setCatFilter(c)}>{c}</button>
        ))}
      </div>

      {/* Reminder List */}
      {filtered.length === 0 ? (
        <div className="empty-state">
          <div className="empty-icon">🔔</div>
          <p>No reminders found</p>
          <button className="btn-primary" onClick={() => setShowForm(true)}>Add your first reminder</button>
        </div>
      ) : (
        <div className="reminders-list">
          {filtered.map(r => (
            <ReminderCard key={r.id} reminder={r} onEdit={handleEdit} />
          ))}
        </div>
      )}

      {showForm && <ReminderForm onClose={handleClose} editData={editData} />}
    </div>
  );
}
