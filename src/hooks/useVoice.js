// src/hooks/useVoice.js
import { useState, useCallback, useRef } from 'react';

export const speakReminder = (text, options = {}) => {
  const synth = window.speechSynthesis;
  if (!synth || !text?.trim()) return false;

  const speakNow = () => {
    const utter = new SpeechSynthesisUtterance(text);
    utter.rate = options.rate || 0.95;
    utter.pitch = options.pitch || 1.1;
    utter.volume = options.volume || 1;
    const voices = synth.getVoices();
    const preferred = voices.find(v => v.name.includes('Google') && v.lang === 'en-US')
      || voices.find(v => v.lang === 'en-US')
      || voices[0];
    if (preferred) utter.voice = preferred;
    if (typeof options.onEnd === 'function') utter.onend = () => options.onEnd();
    if (typeof options.onError === 'function') utter.onerror = (e) => options.onError(e);
    try {
      synth.cancel();
      if (typeof synth.resume === "function") synth.resume();
      synth.speak(utter);
      return true;
    } catch {
      return false;
    }
  };

  const voices = synth.getVoices();
  if (voices.length > 0) return speakNow();

  // Some browsers load voices lazily; retry when they become available.
  let handled = false;
  const trySpeak = () => {
    if (handled) return;
    handled = true;
    speakNow();
    synth.removeEventListener?.("voiceschanged", trySpeak);
  };
  synth.addEventListener?.("voiceschanged", trySpeak);
  setTimeout(trySpeak, 300);
  return true;
};

export const useVoiceInput = () => {
  const [isListening, setIsListening] = useState(false);
  const [transcript, setTranscript] = useState('');
  const [error, setError] = useState(null);
  const recognitionRef = useRef(null);

  const startListening = useCallback(() => {
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      setError('Speech recognition not supported in this browser.');
      return;
    }
    const recognition = new SpeechRecognition();
    recognition.continuous = false;
    recognition.interimResults = true;
    recognition.lang = 'en-US';

    recognition.onstart = () => setIsListening(true);
    recognition.onend = () => setIsListening(false);
    recognition.onerror = (e) => { setError(e.error); setIsListening(false); };
    recognition.onresult = (e) => {
      const t = Array.from(e.results).map(r => r[0].transcript).join('');
      setTranscript(t);
    };

    recognitionRef.current = recognition;
    recognition.start();
  }, []);

  const stopListening = useCallback(() => {
    recognitionRef.current?.stop();
    setIsListening(false);
  }, []);

  const reset = () => setTranscript('');

  return { isListening, transcript, error, startListening, stopListening, reset };
};

// Parse voice command like "Remind me to take medicine tomorrow at 3pm"
export const parseVoiceCommand = (text) => {
  const result = { title: text, dueDate: new Date(), priority: 'medium', category: 'General' };
  const lower = text.toLowerCase();

  // Extract time
  const timeMatch = lower.match(/at (\d{1,2})(?::(\d{2}))?\s*(am|pm)?/i);
  if (timeMatch) {
    let hours = parseInt(timeMatch[1]);
    const mins = parseInt(timeMatch[2] || '0');
    const meridiem = timeMatch[3];
    if (meridiem === 'pm' && hours < 12) hours += 12;
    if (meridiem === 'am' && hours === 12) hours = 0;
    result.dueDate.setHours(hours, mins, 0);
  }

  // Extract date
  const now = new Date();
  if (lower.includes('tomorrow')) {
    result.dueDate = new Date(now);
    result.dueDate.setDate(now.getDate() + 1);
    if (timeMatch) { let h=parseInt(timeMatch[1]); const m=parseInt(timeMatch[2]||'0'); const mer=timeMatch[3]; if(mer==='pm'&&h<12)h+=12; result.dueDate.setHours(h,m,0); }
  } else if (lower.includes('next week')) {
    result.dueDate = new Date(now);
    result.dueDate.setDate(now.getDate() + 7);
  } else if (lower.includes('in an hour')) {
    result.dueDate = new Date(now.getTime() + 3600000);
  } else if (lower.includes('in 30 minutes')) {
    result.dueDate = new Date(now.getTime() + 1800000);
  }

  // Extract priority
  if (lower.includes('urgent') || lower.includes('important') || lower.includes('critical')) result.priority = 'high';
  if (lower.includes('low priority') || lower.includes('whenever')) result.priority = 'low';

  // Extract category
  if (lower.includes('meeting') || lower.includes('call') || lower.includes('appointment')) result.category = 'Work';
  if (lower.includes('medicine') || lower.includes('doctor') || lower.includes('health')) result.category = 'Health';
  if (lower.includes('birthday') || lower.includes('anniversary') || lower.includes('family')) result.category = 'Personal';
  if (lower.includes('buy') || lower.includes('shop') || lower.includes('purchase')) result.category = 'Shopping';

  // Clean title
  result.title = text
    .replace(/remind me to /i, '')
    .replace(/at \d{1,2}(?::\d{2})?\s*(?:am|pm)?/i, '')
    .replace(/tomorrow|next week|in an hour|in 30 minutes/i, '')
    .trim();
  if (!result.title) result.title = text;

  return result;
};
