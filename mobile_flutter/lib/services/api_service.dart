import "dart:convert";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "../config/api_config.dart";
import "../models/reminder_model.dart";

class ModeState {
  final String mode;
  final String source;
  final String autoModeSetting;
  final String? deviceId;
  final int? lastRssi;
  final String? lastUpdateTime;

  const ModeState({
    required this.mode,
    this.source = "manual",
    this.autoModeSetting = "manual",
    this.deviceId,
    this.lastRssi,
    this.lastUpdateTime,
  });

  factory ModeState.fromJson(Map<String, dynamic> json) {
    return ModeState(
      mode: json["mode"]?.toString() ?? "indoor",
      source: json["source"]?.toString() ?? "manual",
      autoModeSetting: json["autoModeSetting"]?.toString() ?? "manual",
      deviceId: json["deviceId"]?.toString(),
      lastRssi: json["lastRssi"] is num ? (json["lastRssi"] as num).toInt() : null,
      lastUpdateTime: json["lastUpdateTime"]?.toString(),
    );
  }
}

class ApiService {
  static String get baseUrl => ApiConfig.baseUrl;
  static const Duration _fastRequestTimeout = Duration(seconds: 5);
  static const Duration _historyRequestTimeout = Duration(seconds: 10);

  void _logRequest(String label, Uri uri) {
    if (kDebugMode) {
      debugPrint("API $label -> $uri");
    }
  }

  Future<http.Response> _get(
    String path,
    Duration timeout, {
    required String label,
  }) async {
    final uri = Uri.parse("${ApiConfig.baseUrl}$path");
    _logRequest(label, uri);
    try {
      final response = await http.get(uri).timeout(timeout);
      if (response.statusCode == 200) {
        return response;
      }
      throw Exception("HTTP ${response.statusCode} at $uri");
    } catch (e) {
      throw Exception("Request failed at $uri: $e");
    }
  }

  Future<http.Response> _post(
    String path,
    Map<String, String> headers,
    String body,
    Duration timeout, {
    required String label,
  }) async {
    final uri = Uri.parse("${ApiConfig.baseUrl}$path");
    _logRequest(label, uri);
    try {
      final response =
          await http.post(uri, headers: headers, body: body).timeout(timeout);
      if (response.statusCode == 200) {
        return response;
      }
      throw Exception("HTTP ${response.statusCode} at $uri");
    } catch (e) {
      throw Exception("Request failed at $uri: $e");
    }
  }

  Future<ModeState> getModeState() async {
    final response = await _get(
      "/api/mode",
      _fastRequestTimeout,
      label: "getModeState",
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ModeState.fromJson(body);
  }

  Future<String> getMode() async {
    final state = await getModeState();
    return state.mode;
  }

  Future<ModeState> updateMode({
    required String mode,
    required String source,
    String? deviceId,
    int? rssi,
    String? reason,
    String? autoModeSetting,
  }) async {
    final payload = <String, dynamic>{
      "mode": mode,
      "source": source,
      "timestamp": DateTime.now().toUtc().toIso8601String(),
    };
    if (deviceId != null && deviceId.isNotEmpty) payload["deviceId"] = deviceId;
    if (rssi != null) payload["rssi"] = rssi;
    if (reason != null && reason.isNotEmpty) payload["reason"] = reason;
    if (autoModeSetting != null) payload["autoModeSetting"] = autoModeSetting;

    final response = await _post(
      "/api/mode",
      {"Content-Type": "application/json"},
      jsonEncode(payload),
      _fastRequestTimeout,
      label: "updateMode",
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ModeState.fromJson(body);
  }

  Future<ReminderModel?> getLatestReminder() async {
    final response = await _get(
      "/api/reminders/latest",
      _fastRequestTimeout,
      label: "getLatestReminder",
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body["data"];
    if (data == null) return null;
    return ReminderModel.fromJson(data as Map<String, dynamic>);
  }

  Future<List<ReminderModel>> getHistory({int limit = 30}) async {
    final response = await _get(
      "/api/reminders/history?limit=$limit",
      _historyRequestTimeout,
      label: "getHistory",
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (body["data"] as List<dynamic>? ?? []);
    return data
        .map((item) => ReminderModel.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> acknowledgeReminder(String id) async {
    await _post(
      "/api/reminders/$id/ack",
      {"Content-Type": "application/json"},
      jsonEncode({"acknowledged_by": "android_phone"}),
      _fastRequestTimeout,
      label: "acknowledgeReminder",
    );
  }

  Future<void> registerMobileFcmToken({
    required String token,
    String platform = "android",
    String? deviceId,
  }) async {
    final payload = <String, dynamic>{
      "token": token,
      "platform": platform,
      if (deviceId != null && deviceId.isNotEmpty) "device_id": deviceId,
    };
    await _post(
      "/api/devices/mobile-token",
      {"Content-Type": "application/json"},
      jsonEncode(payload),
      _fastRequestTimeout,
      label: "registerMobileFcmToken",
    );
  }
}
