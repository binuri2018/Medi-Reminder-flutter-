import "package:firebase_core/firebase_core.dart" show FirebaseOptions;
import "package:flutter/foundation.dart"
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          "DefaultFirebaseOptions are not configured for Linux yet.",
        );
      default:
        throw UnsupportedError(
          "DefaultFirebaseOptions are not configured for this platform.",
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBuVaMEuagGrkcn-OFQqZi4NMNLVqVvmZg',
    appId: '1:1071519378209:web:af5d20a25ef575ab7e6c60',
    messagingSenderId: '1071519378209',
    projectId: 'research-2d95a',
    authDomain: 'research-2d95a.firebaseapp.com',
    storageBucket: 'research-2d95a.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAnZpHJu3auMwKYuQz0hOyB6CIwbxfdDoU',
    appId: '1:1071519378209:android:45a5e6206220c38b7e6c60',
    messagingSenderId: '1071519378209',
    projectId: 'research-2d95a',
    storageBucket: 'research-2d95a.firebasestorage.app',
  );

  // Using same Firebase project details for Android simulation app.

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyBkek3C-B1-llsWxViURUatY4-xtPs6LKA',
    appId: '1:1071519378209:ios:4767437765a2ec897e6c60',
    messagingSenderId: '1071519378209',
    projectId: 'research-2d95a',
    storageBucket: 'research-2d95a.firebasestorage.app',
    iosBundleId: 'com.example.mobileFlutter',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBkek3C-B1-llsWxViURUatY4-xtPs6LKA',
    appId: '1:1071519378209:ios:4767437765a2ec897e6c60',
    messagingSenderId: '1071519378209',
    projectId: 'research-2d95a',
    storageBucket: 'research-2d95a.firebasestorage.app',
    iosBundleId: 'com.example.mobileFlutter',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBuVaMEuagGrkcn-OFQqZi4NMNLVqVvmZg',
    appId: '1:1071519378209:web:058721307cd1c5dd7e6c60',
    messagingSenderId: '1071519378209',
    projectId: 'research-2d95a',
    authDomain: 'research-2d95a.firebaseapp.com',
    storageBucket: 'research-2d95a.firebasestorage.app',
  );

}