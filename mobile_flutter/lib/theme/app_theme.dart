import "package:flutter/material.dart";
import "package:google_fonts/google_fonts.dart";

/// Visual design tokens and [ThemeData] for the mobile reminder app.
abstract final class AppColors {
  static const Color tealDeep = Color(0xFF0F766E);
  static const Color tealMuted = Color(0xFF14B8A6);
  static const Color slateBg = Color(0xFFF1F5F9);
  static const Color slateCard = Color(0xFFFFFFFF);
  static const Color outdoorGlow = Color(0xFFFFEDD5);
  static const Color outdoorAccent = Color(0xFFEA580C);
  static const Color indoorGlow = Color(0xFFD1FAE5);
  static const Color indoorAccent = Color(0xFF059669);
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color errorContainer = Color(0xFFFEE2E2);
  static const Color errorBorder = Color(0xFFF87171);
}

abstract final class AppTheme {
  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.tealDeep,
      brightness: Brightness.light,
      primary: AppColors.tealDeep,
      onPrimary: Colors.white,
      secondary: AppColors.tealMuted,
      onSecondary: Colors.white,
      surface: AppColors.slateCard,
      onSurface: AppColors.textPrimary,
      error: const Color(0xFFDC2626),
    );

    final textTheme = GoogleFonts.plusJakartaSansTextTheme().apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.slateBg,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        titleTextStyle: GoogleFonts.plusJakartaSans(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.slateCard,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          side: BorderSide(
            color: AppColors.tealDeep.withValues(alpha: 0.35),
          ),
          foregroundColor: AppColors.tealDeep,
          textStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.slateCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        showDragHandle: true,
      ),
      dividerTheme: DividerThemeData(
        color: AppColors.textSecondary.withValues(alpha: 0.12),
        thickness: 1,
      ),
    );
  }
}
