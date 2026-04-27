import "package:flutter/material.dart";
import "package:google_fonts/google_fonts.dart";

import "../theme/app_theme.dart";

class ModeBadge extends StatelessWidget {
  const ModeBadge({super.key, required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final isOutdoor = mode.trim().toLowerCase() == "outdoor";
    final bg = isOutdoor ? AppColors.outdoorGlow : AppColors.indoorGlow;
    final accent = isOutdoor ? AppColors.outdoorAccent : AppColors.indoorAccent;
    final icon = isOutdoor ? Icons.wb_sunny_rounded : Icons.home_rounded;
    final label = isOutdoor ? "Outdoor" : "Indoor";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            bg,
            bg.withValues(alpha: 0.65),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: accent, size: 26),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Current mode",
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                  letterSpacing: 0.3,
                ),
              ),
              Text(
                label,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
