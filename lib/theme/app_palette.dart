import 'package:flutter/material.dart';

/// Accent roles a palette is allowed to change.
///
/// Surface, outline and text roles stay in [studioTheme] so every palette keeps
/// the existing layout contrast and the app still looks like the same product.
@immutable
class PaletteAccent {
  const PaletteAccent({
    required this.primary,
    required this.onPrimary,
    required this.container,
    required this.onContainer,
  });

  final Color primary;
  final Color onPrimary;
  final Color container;
  final Color onContainer;
}

/// A selectable colour style.
///
/// Only the accent roles and the seed used for the derived M3 scheme vary; the
/// neutral surface stack is fixed per brightness in `studio_theme.dart`.
@immutable
class AppPalette {
  const AppPalette({
    required this.id,
    required this.name,
    required this.description,
    required this.swatch,
    required this.seed,
    required this.light,
    required this.dark,
  });

  final String id;
  final String name;
  final String description;

  /// Colour shown in the picker, independent of the current brightness.
  final Color swatch;
  final Color seed;
  final PaletteAccent light;
  final PaletteAccent dark;

  PaletteAccent accentFor(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// Id of the shipped design. Anything unknown falls back to it.
const studioDefaultPaletteId = 'studio';

const List<AppPalette> appPalettes = [
  AppPalette(
    id: studioDefaultPaletteId,
    name: '原生靛蓝',
    description: '默认配色，完全保持现有设计',
    swatch: Color(0xFF6875D9),
    seed: Color(0xFF6875D9),
    light: PaletteAccent(
      primary: Color(0xFF5C69C6),
      onPrimary: Colors.white,
      container: Color(0xFFEAEDFF),
      onContainer: Color(0xFF505DAC),
    ),
    dark: PaletteAccent(
      primary: Color(0xFFAAB4FF),
      onPrimary: Color(0xFF202749),
      container: Color(0xFF32394F),
      onContainer: Color(0xFFC5CEFF),
    ),
  ),
  AppPalette(
    id: 'ocean',
    name: '海盐蓝',
    description: '偏冷的青蓝色，适合长时间处理素材',
    swatch: Color(0xFF2C8FA8),
    seed: Color(0xFF2C8FA8),
    light: PaletteAccent(
      primary: Color(0xFF157A93),
      onPrimary: Colors.white,
      container: Color(0xFFDDF2F8),
      onContainer: Color(0xFF0F5C70),
    ),
    dark: PaletteAccent(
      primary: Color(0xFF86D6E8),
      onPrimary: Color(0xFF06323D),
      container: Color(0xFF1F3F49),
      onContainer: Color(0xFFC4EAF3),
    ),
  ),
  AppPalette(
    id: 'forest',
    name: '松林绿',
    description: '低饱和的青绿，界面更安静',
    swatch: Color(0xFF3D8B63),
    seed: Color(0xFF3D8B63),
    light: PaletteAccent(
      primary: Color(0xFF2F7452),
      onPrimary: Colors.white,
      container: Color(0xFFE1F2E8),
      onContainer: Color(0xFF245840),
    ),
    dark: PaletteAccent(
      primary: Color(0xFF9AD8B5),
      onPrimary: Color(0xFF0B2A1D),
      container: Color(0xFF254234),
      onContainer: Color(0xFFC7EBD8),
    ),
  ),
  AppPalette(
    id: 'amber',
    name: '秋日橙',
    description: '暖色强调，对比更明显',
    swatch: Color(0xFFC77A33),
    seed: Color(0xFFC77A33),
    light: PaletteAccent(
      primary: Color(0xFFA9621F),
      onPrimary: Colors.white,
      container: Color(0xFFFFEEDB),
      onContainer: Color(0xFF7B4614),
    ),
    dark: PaletteAccent(
      primary: Color(0xFFF3BE86),
      onPrimary: Color(0xFF3A2110),
      container: Color(0xFF4A3524),
      onContainer: Color(0xFFFFDFC0),
    ),
  ),
  AppPalette(
    id: 'rose',
    name: '莓果红',
    description: '偏红的强调色，状态与按钮更醒目',
    swatch: Color(0xFFC25C7B),
    seed: Color(0xFFC25C7B),
    light: PaletteAccent(
      primary: Color(0xFFA8475F),
      onPrimary: Colors.white,
      container: Color(0xFFFBE7ED),
      onContainer: Color(0xFF7E3347),
    ),
    dark: PaletteAccent(
      primary: Color(0xFFF4AABD),
      onPrimary: Color(0xFF3C1621),
      container: Color(0xFF4A2C35),
      onContainer: Color(0xFFFFD6E0),
    ),
  ),
  AppPalette(
    id: 'graphite',
    name: '石墨灰',
    description: '近乎无彩色，把注意力留给素材',
    swatch: Color(0xFF5A6472),
    seed: Color(0xFF5A6472),
    light: PaletteAccent(
      primary: Color(0xFF4B5563),
      onPrimary: Colors.white,
      container: Color(0xFFE9ECF1),
      onContainer: Color(0xFF39414D),
    ),
    dark: PaletteAccent(
      primary: Color(0xFFB8C2D0),
      onPrimary: Color(0xFF1B2027),
      container: Color(0xFF30363F),
      onContainer: Color(0xFFD7E0EA),
    ),
  ),
];

/// Palette for [id], or the shipped default when the id is unknown.
AppPalette paletteById(String? id) => tryPaletteById(id) ?? appPalettes.first;

/// Palette for [id], or null when nothing matches.
AppPalette? tryPaletteById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final palette in appPalettes) {
    if (palette.id == id) return palette;
  }
  return null;
}
