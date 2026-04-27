import "package:flutter/material.dart";

class ModeBadge extends StatelessWidget {
  const ModeBadge({super.key, required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final bool isOutdoor = mode == "outdoor";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isOutdoor ? Colors.red.shade100 : Colors.teal.shade100,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        "Mode: ${mode.toUpperCase()}",
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: isOutdoor ? Colors.red.shade800 : Colors.teal.shade800,
        ),
      ),
    );
  }
}
