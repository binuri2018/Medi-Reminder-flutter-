import "package:flutter/material.dart";

import "../models/reminder_model.dart";

class ReminderCard extends StatelessWidget {
  const ReminderCard({
    super.key,
    required this.reminder,
    required this.onAcknowledge,
  });

  final ReminderModel reminder;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reminder.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(reminder.message.isEmpty ? "No details provided." : reminder.message),
            const SizedBox(height: 8),
            Text("Status: ${reminder.status}"),
            Text("Time: ${formatTimestampToLocal(reminder.timestamp)}"),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: reminder.status == "acknowledged" ? null : onAcknowledge,
                    child: const Text("Acknowledge / Done"),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {},
                    child: const Text("Remind Again"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
