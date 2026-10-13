import 'package:flutter/material.dart';

/// Warm coral + cream palette, matching the app icon.
class AppColors {
  static const coral = Color(0xFFFF7A6B);
  static const cream = Color(0xFFFFF8F0);
  static const mint = Color(0xFF5CC9A7);
  static const warning = Color(0xFFFFA94D);
  static const danger = Color(0xFFE5484D);
  static const income = Color(0xFF2FA37A);
  static const expense = Color(0xFF3D3D3D);
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.coral,
    brightness: brightness,
    surface: brightness == Brightness.light ? AppColors.cream : null,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: brightness == Brightness.light ? Colors.white : scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // tinted so fields stay visible both on the cream page and on white cards
      fillColor: brightness == Brightness.light ? const Color(0xFFFFF1EA) : scheme.surfaceContainerHighest,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

/// Progress color for a used-percentage of the monthly limit.
Color usageColor(int percent) {
  if (percent >= 100) return AppColors.danger;
  if (percent >= 80) return AppColors.warning;
  return AppColors.mint;
}
