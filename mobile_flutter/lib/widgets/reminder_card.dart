import "package:flutter/material.dart";
import "package:google_fonts/google_fonts.dart";

import "../models/reminder_model.dart";
import "../theme/app_theme.dart";

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
    final pending = isReminderPending(reminder.status);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.slateCard,
            pending
                ? AppColors.tealDeep.withValues(alpha: 0.04)
                : AppColors.slateBg,
          ],
        ),
        border: Border.all(
          color: pending
              ? AppColors.tealDeep.withValues(alpha: 0.2)
              : AppColors.textSecondary.withValues(alpha: 0.12),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.tealDeep.withValues(alpha: pending ? 0.1 : 0.04),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: pending
                        ? AppColors.tealDeep.withValues(alpha: 0.12)
                        : AppColors.textSecondary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    pending ? Icons.notifications_active_rounded : Icons.task_alt_rounded,
                    color: pending ? AppColors.tealDeep : AppColors.textSecondary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reminder.title.trim().isEmpty ? "Reminder" : reminder.title.trim(),
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _StatusChip(status: reminder.status, pending: pending),
                    ],
                  ),
                ),
              ],
            ),
            if (reminder.message.trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                reminder.message.trim(),
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 15,
                  height: 1.45,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 18,
                  color: AppColors.textSecondary.withValues(alpha: 0.85),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    formatTimestampToLocal(reminder.timestamp),
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: pending ? onAcknowledge : null,
                icon: const Icon(Icons.check_circle_outline_rounded, size: 22),
                label: Text(
                  pending ? "Mark as done" : "Already completed",
                  style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: pending ? scheme.primary : AppColors.textSecondary.withValues(alpha: 0.35),
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.pending});

  final String status;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final label = pending ? "Pending" : _prettyStatus(status);
    final color = pending ? AppColors.outdoorAccent : AppColors.indoorAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  String _prettyStatus(String s) {
    final t = s.trim().toLowerCase();
    if (t.isEmpty) return "Unknown";
    return "${t[0].toUpperCase()}${t.length > 1 ? t.substring(1) : ""}";
  }
}
