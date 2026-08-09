import 'package:flutter/material.dart';

/// Design system do Brasil Net Pro.
///
/// Tres cores, sem excecao: preto absoluto, verde neon e amarelo ouro.
/// Azul e proibido em qualquer elemento — inclusive nos estados padrao do
/// Material, que puxam azul se a gente nao sobrescrever explicitamente (por
/// isso o ColorScheme abaixo redefine primary, secondary e tertiary).
class AppColors {
  AppColors._();

  /// Preto absoluto: e o fundo, nao um cinza escuro.
  static const background = Color(0xFF000000);

  /// Superficies sobem em passos minimos para nao "clarear" o preto.
  static const surface = Color(0xFF0A0A0A);
  static const surfaceAlt = Color(0xFF141414);
  static const border = Color(0xFF1F1F1F);

  /// Verde neon — acao, conectado, foco.
  static const primary = Color(0xFF39FF14);

  /// Amarelo ouro — destaque secundario, avisos, valores.
  static const gold = Color(0xFFFFD700);

  static const success = Color(0xFF39FF14);
  static const warning = Color(0xFFFFD700);
  static const danger = Color(0xFFFF3B30);

  static const textMuted = Color(0xFF8A8A8A);
}

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,

    // Sem isto o Material aplica azul em ripple, selecao de texto, switches e
    // indicadores — os pontos onde o azul costuma reaparecer sem aviso.
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primary,
      onPrimary: Colors.black,
      secondary: AppColors.gold,
      onSecondary: Colors.black,
      tertiary: AppColors.gold,
      surface: AppColors.surface,
      onSurface: Colors.white,
      error: AppColors.danger,
      onError: Colors.black,
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      foregroundColor: Colors.white,
    ),

    cardTheme: CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      margin: EdgeInsets.zero,
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceAlt,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.black,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.primary),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? AppColors.primary.withValues(alpha: 0.3)
            : AppColors.surfaceAlt,
      ),
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.primary,
      linearTrackColor: AppColors.surfaceAlt,
    ),

    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1),

    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceAlt,
      contentTextStyle: TextStyle(color: Colors.white),
    ),

    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.primary,
      selectionColor: Color(0x3339FF14),
      selectionHandleColor: AppColors.primary,
    ),
  );
}
