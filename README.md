# RemindAI - Smart Reminder System

A full-featured reminder system with voice input/output, CRUD operations, real-time sync, and analytics dashboard.

## Features
- ✅ **CRUD** - Create, Read, Update, Delete reminders
- 🎤 **Voice Input** - Add reminders by speaking (Web Speech API)
- 🔊 **Voice Output** - Reminders announced via speaker at due time
- 📊 **Analytics Dashboard** - Charts for categories, priorities, activity, completion rates
- 🔥 **Firebase** - Real-time Firestore sync
- ⏰ **Auto Alerts** - Checks every 5 seconds, fires voice alert when due
- 🔁 **Repeat** - Daily, weekly, monthly repeats
- 🏷️ **Categories** - Work, Health, Personal, Shopping, Finance, etc.
- ⚡ **Priority** - High, Medium, Low with color coding
- 📱 **Responsive** - Works on mobile

## Setup

### 1. Firebase Setup
1. Go to https://console.firebase.google.com
2. Create a new project
3. Add a Web app
4. Copy the config and paste into `src/firebase/config.js`
5. Enable **Firestore Database** in the Firebase console
6. Set Firestore rules to allow read/write (for dev):
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if true;
    }
  }
}
```

### 2. Install & Run
```bash
npm install
npm start
```

### 3. Build for Production
```bash
npm run build
```

## Voice Commands Examples
- "Remind me to take medicine tomorrow at 3pm"
- "Call John at 2pm urgent meeting"
- "Buy groceries tomorrow"
- "Doctor appointment next week at 10am"

## Tech Stack
- React 18
- Firebase Firestore
- React Router v6
- Recharts
- Web Speech API (SpeechRecognition + SpeechSynthesis)
- react-hot-toast
- date-fns
