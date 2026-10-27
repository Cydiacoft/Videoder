import 'package:flutter/material.dart';

ThemeData studioTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
          seedColor: const Color(0xFF6875D9), brightness: brightness)
      .copyWith(
    primary: dark ? const Color(0xFFAAB4FF) : const Color(0xFF5C69C6),
    onPrimary: dark ? const Color(0xFF202749) : Colors.white,
    primaryContainer: dark ? const Color(0xFF32394F) : const Color(0xFFEAEDFF),
    onPrimaryContainer:
        dark ? const Color(0xFFC5CEFF) : const Color(0xFF505DAC),
    surface: dark ? const Color(0xFF202126) : const Color(0xFFF8F9FC),
    surfaceContainerLowest: dark ? const Color(0xFF1A1B20) : Colors.white,
    surfaceContainerLow:
        dark ? const Color(0xFF26272E) : const Color(0xFFF0F2F7),
    surfaceContainerHighest:
        dark ? const Color(0xFF34353E) : const Color(0xFFE8EBF2),
    onSurface: dark ? const Color(0xFFE4E5EE) : const Color(0xFF292D40),
    onSurfaceVariant: dark ? const Color(0xFF9A9DAF) : const Color(0xFF7A8095),
    outlineVariant: dark ? const Color(0xFF383A45) : const Color(0xFFE4E7F0),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  final button = ButtonStyle(
      visualDensity: VisualDensity.standard,
      minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
      shape: WidgetStatePropertyAll(shape),
      textStyle: const WidgetStatePropertyAll(TextStyle(
          fontFamily: 'Microsoft YaHei UI',
          fontFamilyFallback: [
            'Microsoft YaHei',
            'Segoe UI',
            'PingFang SC',
            'Noto Sans CJK SC'
          ],
          fontSize: 13,
          fontWeight: FontWeight.w400,
          letterSpacing: 0)));
  final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: colors.outlineVariant));
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colors,
    fontFamily: 'Microsoft YaHei UI',
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'Segoe UI',
      'PingFang SC',
      'Noto Sans CJK SC'
    ],
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    scaffoldBackgroundColor: colors.surface,
    textTheme: TextTheme(
        bodyLarge: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            letterSpacing: 0,
            color: colors.onSurface),
        bodyMedium:
            TextStyle(fontSize: 13, letterSpacing: 0, color: colors.onSurface),
        bodySmall: TextStyle(
            fontSize: 12, letterSpacing: 0, color: colors.onSurfaceVariant),
        labelLarge: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w400, letterSpacing: 0),
        // Dropdowns inherit titleMedium; keep small Chinese glyphs regular.
        titleMedium: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w400, letterSpacing: 0),
        titleLarge: const TextStyle(
            fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: 0)),
    appBarTheme: AppBarTheme(
        toolbarHeight: 64,
        backgroundColor: colors.surface,
        scrolledUnderElevation: 0,
        elevation: 0,
        titleTextStyle: TextStyle(
            fontFamily: 'Microsoft YaHei UI',
            fontFamilyFallback: const [
              'Microsoft YaHei',
              'Segoe UI',
              'PingFang SC',
              'Noto Sans CJK SC'
            ],
            fontSize: 21,
            fontWeight: FontWeight.w600,
            color: colors.onSurface)),
    inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: colors.surfaceContainerLowest,
        border: border,
        enabledBorder: border,
        focusedBorder:
            border.copyWith(borderSide: BorderSide(color: colors.primary)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        labelStyle: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: button.copyWith(
            side: WidgetStatePropertyAll(
                BorderSide(color: colors.outlineVariant)))),
    textButtonTheme: TextButtonThemeData(style: button),
    cardTheme: CardThemeData(
        color: colors.surfaceContainerLowest,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: colors.outlineVariant))),
    dividerTheme:
        DividerThemeData(color: colors.outlineVariant, thickness: 1, space: 1),
    listTileTheme: const ListTileThemeData(dense: true, minTileHeight: 52),
    tooltipTheme:
        const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
  );
}

class StudioPanel extends StatelessWidget {
  const StudioPanel(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(18)});
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child));
}

class StudioTag extends StatelessWidget {
  const StudioTag(this.label, {super.key, this.icon, this.accent = false});
  final String label;
  final IconData? icon;
  final bool accent;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final color = accent ? c.primary : c.onSurfaceVariant;
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: accent ? c.primaryContainer : c.surfaceContainerLow,
            borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 5)
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: color))
        ]));
  }
}
