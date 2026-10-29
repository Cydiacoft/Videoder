import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_palette.dart';

/// User-controlled look of the app: accent palette plus the experimental
/// custom background. Kept separate from [AppSettings] because none of this
/// affects media processing.
class AppearanceSettings {
  static const _unchanged = Object();

  static const double minBlur = 0;
  static const double maxBlur = 24;
  static const double minVeil = 0.35;
  static const double maxVeil = 0.95;
  static const double defaultBlur = 8;
  static const double defaultVeil = 0.82;

  final String paletteId;
  final String? backgroundImagePath;
  final double backgroundBlur;
  final double backgroundVeil;

  const AppearanceSettings({
    this.paletteId = studioDefaultPaletteId,
    this.backgroundImagePath,
    this.backgroundBlur = defaultBlur,
    this.backgroundVeil = defaultVeil,
  });

  AppPalette get palette => paletteById(paletteId);

  bool get hasBackground =>
      backgroundImagePath != null && backgroundImagePath!.isNotEmpty;

  static double clampBlur(double value) =>
      value.clamp(minBlur, maxBlur).toDouble();

  static double clampVeil(double value) =>
      value.clamp(minVeil, maxVeil).toDouble();

  AppearanceSettings copyWith({
    String? paletteId,
    Object? backgroundImagePath = _unchanged,
    double? backgroundBlur,
    double? backgroundVeil,
  }) =>
      AppearanceSettings(
        paletteId: paletteId ?? this.paletteId,
        backgroundImagePath: identical(backgroundImagePath, _unchanged)
            ? this.backgroundImagePath
            : backgroundImagePath as String?,
        backgroundBlur: clampBlur(backgroundBlur ?? this.backgroundBlur),
        backgroundVeil: clampVeil(backgroundVeil ?? this.backgroundVeil),
      );
}

class AppearanceNotifier extends StateNotifier<AppearanceSettings> {
  AppearanceNotifier() : super(const AppearanceSettings()) {
    ready = _load();
  }

  late final Future<void> ready;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    String? text(String key) {
      final value = prefs.getString(key);
      return (value == null || value.isEmpty) ? null : value;
    }

    final palette = tryPaletteById(text('theme_palette'));
    final blur = prefs.getDouble('theme_background_blur');
    final veil = prefs.getDouble('theme_background_veil');
    if (!mounted) return;
    state = AppearanceSettings(
      paletteId: palette?.id ?? studioDefaultPaletteId,
      backgroundImagePath: text('theme_background_image'),
      backgroundBlur:
          AppearanceSettings.clampBlur(blur ?? AppearanceSettings.defaultBlur),
      backgroundVeil:
          AppearanceSettings.clampVeil(veil ?? AppearanceSettings.defaultVeil),
    );
  }

  Future<void> setPalette(String id) async {
    await ready;
    if (tryPaletteById(id) == null) {
      throw const FormatException('未知的配色方案');
    }
    if (state.paletteId == id) return;
    state = state.copyWith(paletteId: id);
    await _persist();
  }

  Future<void> setBackgroundImage(String? path) async {
    await ready;
    final value = (path == null || path.trim().isEmpty) ? null : path;
    if (state.backgroundImagePath == value) return;
    state = state.copyWith(backgroundImagePath: value);
    await _persist();
  }

  /// [persist] is false while a slider is being dragged; call it again on change
  /// end so dragging does not write to disk on every frame.
  Future<void> setBackgroundBlur(double value, {bool persist = true}) async {
    await ready;
    final clamped = AppearanceSettings.clampBlur(value);
    if (state.backgroundBlur != clamped) {
      state = state.copyWith(backgroundBlur: clamped);
    }
    if (persist) await _persist();
  }

  Future<void> setBackgroundVeil(double value, {bool persist = true}) async {
    await ready;
    final clamped = AppearanceSettings.clampVeil(value);
    if (state.backgroundVeil != clamped) {
      state = state.copyWith(backgroundVeil: clamped);
    }
    if (persist) await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final current = state;
    await prefs.setString('theme_palette', current.paletteId);
    if (current.backgroundImagePath == null) {
      await prefs.remove('theme_background_image');
    } else {
      await prefs.setString(
          'theme_background_image', current.backgroundImagePath!);
    }
    await prefs.setDouble('theme_background_blur', current.backgroundBlur);
    await prefs.setDouble('theme_background_veil', current.backgroundVeil);
  }
}

final appearanceProvider =
    StateNotifierProvider<AppearanceNotifier, AppearanceSettings>(
        (ref) => AppearanceNotifier());
