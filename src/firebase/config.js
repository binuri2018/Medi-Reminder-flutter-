// src/firebase/config.js
// Replace with your Firebase project config from https://console.firebase.google.com
import { initializeApp } from 'firebase/app';
import { getFirestore } from 'firebase/firestore';
import { getAuth } from 'firebase/auth';

const firebaseConfig = {
  apiKey: "AIzaSyBuVaMEuagGrkcn-OFQqZi4NMNLVqVvmZg",
  authDomain: "research-2d95a.firebaseapp.com",
  projectId: "research-2d95a",
  storageBucket: "research-2d95a.firebasestorage.app",
  messagingSenderId: "1071519378209",
  appId: "1:1071519378209:web:af5d20a25ef575ab7e6c60"
};

const app = initializeApp(firebaseConfig);
export const db = getFirestore(app);
export const auth = getAuth(app);
export default app;
