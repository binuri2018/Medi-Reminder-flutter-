class ReminderModel {
  final String id;
  final String title;
  final String message;
  final String timestamp;
  final String mode;
  final String status;

  ReminderModel({
    required this.id,
    required this.title,
    required this.message,
    required this.timestamp,
    required this.mode,
    required this.status,
  });

  factory ReminderModel.fromJson(Map<String, dynamic> json) {
    return ReminderModel(
      id: json["id"] ?? "",
      title: json["title"] ?? "",
      message: json["message"] ?? "",
      timestamp: json["timestamp"] ?? "",
      mode: json["mode"] ?? "indoor",
      status: json["status"] ?? "pending",
    );
  }
}

String formatTimestampToLocal(String rawTimestamp) {
  final parsed = DateTime.tryParse(rawTimestamp);
  if (parsed == null) return rawTimestamp;
  final local = parsed.toLocal();
  String two(int v) => v.toString().padLeft(2, "0");
  final hour12 = local.hour == 0
      ? 12
      : (local.hour > 12 ? local.hour - 12 : local.hour);
  final suffix = local.hour >= 12 ? "PM" : "AM";
  return "${local.year}-${two(local.month)}-${two(local.day)} "
      "${two(hour12)}:${two(local.minute)} $suffix";
}
