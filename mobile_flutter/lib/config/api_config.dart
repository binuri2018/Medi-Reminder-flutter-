/// Central configuration for the backend API base URL.
///
/// Resolution order:
///   1. `--dart-define=API_BASE_URL=...` at build/run time. ALWAYS use the
///      LAN IP of the machine running the FastAPI backend. Example:
///        flutter run -d <device> --dart-define=API_BASE_URL=http://192.168.1.42:8000
///   2. The compile-time default below.
///
/// HARD-LEARNED LESSON: do NOT pass the literal placeholder string
/// `YOUR_CURRENT_PC_IP` from documentation. The Dart resolver will happily
/// keep that as the host name, every HTTP call will hit
/// `http://your_current_pc_ip:8000/...`, DNS will fail with `errno = 7`,
/// and every part of the app that depends on the backend (Done button,
/// closed-app notifications, voice TTS) will silently break. The
/// [isMisconfigured] helper detects this case so the UI can show a loud
/// error instead of failing quietly.
class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    "API_BASE_URL",
    // Sensible default for local development on the dev workstation.
    // Override per-run with --dart-define=API_BASE_URL=http://<your LAN ip>:8000
    defaultValue: "http://10.235.154.28:8000",
  );

  /// Returns true when the resolved [baseUrl] contains a documentation
  /// placeholder (e.g. `YOUR_CURRENT_PC_IP`, `<PC_LAN_IP>`) instead of a
  /// real IP. Used by the home screen to show a screaming red banner so
  /// the user can fix the launch command.
  static bool get isMisconfigured {
    final lower = baseUrl.toLowerCase();
    const placeholders = <String>[
      "your_current_pc_ip",
      "your_pc_ip",
      "<pc_lan_ip>",
      "<your_pc_ip>",
      "<your-pc-ip>",
      "<pc-lan-ip>",
      "pc_lan_ip",
      "pc-lan-ip",
    ];
    for (final p in placeholders) {
      if (lower.contains(p)) return true;
    }
    return false;
  }
}
