import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/main.dart';
import 'package:videoader/providers/appearance_provider.dart';
import 'package:videoader/theme/app_palette.dart';
import 'package:videoader/theme/studio_theme.dart';
import 'package:videoader/widgets/studio_background.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the default palette reproduces the shipped theme exactly', () {
    final light = studioTheme(Brightness.light);
    expect(light.colorScheme.primary, const Color(0xFF5C69C6));
    expect(light.colorScheme.onPrimary, Colors.white);
    expect(light.colorScheme.primaryContainer, const Color(0xFFEAEDFF));
    expect(light.colorScheme.onPrimaryContainer, const Color(0xFF505DAC));
    expect(light.colorScheme.surface, const Color(0xFFF8F9FC));

    final dark = studioTheme(Brightness.dark);
    expect(dark.colorScheme.primary, const Color(0xFFAAB4FF));
    expect(dark.colorScheme.onPrimary, const Color(0xFF202749));
    expect(dark.colorScheme.primaryContainer, const Color(0xFF32394F));
    expect(dark.colorScheme.onPrimaryContainer, const Color(0xFFC5CEFF));
    expect(dark.colorScheme.surface, const Color(0xFF202126));
  });

  test('a palette recolours accents only and leaves the design untouched', () {
    final base = studioTheme(Brightness.light);
    final ocean = studioTheme(Brightness.light, paletteId: 'ocean');
    expect(ocean.colorScheme.primary, isNot(base.colorScheme.primary));
    // Neutral surfaces, text and outlines must not move or the layout contrast
    // the app was designed around would break.
    expect(ocean.colorScheme.surface, base.colorScheme.surface);
    expect(ocean.colorScheme.surfaceContainerLowest,
        base.colorScheme.surfaceContainerLowest);
    expect(ocean.colorScheme.surfaceContainerLow,
        base.colorScheme.surfaceContainerLow);
    expect(ocean.colorScheme.surfaceContainerHighest,
        base.colorScheme.surfaceContainerHighest);
    expect(ocean.colorScheme.onSurface, base.colorScheme.onSurface);
    expect(ocean.colorScheme.onSurfaceVariant, base.colorScheme.onSurfaceVariant);
    expect(ocean.colorScheme.outlineVariant, base.colorScheme.outlineVariant);
    expect(ocean.scaffoldBackgroundColor, base.scaffoldBackgroundColor);
    expect(ocean.textTheme.bodyMedium?.fontSize,
        base.textTheme.bodyMedium?.fontSize);
  });

  test('unknown palette ids fall back to the shipped design', () {
    expect(paletteById('does-not-exist').id, studioDefaultPaletteId);
    expect(paletteById(null).id, studioDefaultPaletteId);
    expect(tryPaletteById(''), isNull);
    expect(tryPaletteById('forest')?.name, '松林绿');
  });

  test('appearance choices persist and reload', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = AppearanceNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;

    await notifier.setPalette('forest');
    await notifier.setBackgroundImage(r'C:\pics\wall.jpg');
    await notifier.setBackgroundBlur(40);
    await notifier.setBackgroundVeil(0.1);
    expect(notifier.state.backgroundBlur, AppearanceSettings.maxBlur);
    expect(notifier.state.backgroundVeil, AppearanceSettings.minVeil);

    final restored = AppearanceNotifier();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.state.paletteId, 'forest');
    expect(restored.state.backgroundImagePath, r'C:\pics\wall.jpg');
    expect(restored.state.hasBackground, isTrue);
    expect(restored.state.backgroundBlur, AppearanceSettings.maxBlur);
    expect(restored.state.backgroundVeil, AppearanceSettings.minVeil);
  });

  test('an unknown saved palette is ignored on load', () async {
    SharedPreferences.setMockInitialValues({'theme_palette': 'legacy-theme'});
    final notifier = AppearanceNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;
    expect(notifier.state.paletteId, studioDefaultPaletteId);
  });

  test('an unknown palette cannot be applied at runtime', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = AppearanceNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;
    await expectLater(
        notifier.setPalette('nope'), throwsA(isA<FormatException>()));
    expect(notifier.state.paletteId, studioDefaultPaletteId);
  });

  test('clearing the background removes the stored path', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = AppearanceNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;
    await notifier.setBackgroundImage(r'C:\pics\wall.jpg');
    expect(notifier.state.hasBackground, isTrue);
    await notifier.setBackgroundImage(null);
    expect(notifier.state.hasBackground, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_background_image'), isNull);
  });

  test('dragging a slider updates state without writing to disk', () async {
    SharedPreferences.setMockInitialValues({'theme_background_blur': 4.0});
    final notifier = AppearanceNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;
    await notifier.setBackgroundBlur(12, persist: false);
    expect(notifier.state.backgroundBlur, 12);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('theme_background_blur'), 4.0);

    await notifier.setBackgroundBlur(12);
    expect(prefs.getDouble('theme_background_blur'), 12);
  });

  testWidgets('a saved palette is applied to the running shell',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'theme_palette': 'ocean',
      'theme_background_image': r'C:\definitely-missing\wall.png',
    });
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: VideoaderApp()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final theme = Theme.of(tester.element(find.byType(MainLayout)));
    expect(theme.colorScheme.primary, const Color(0xFF157A93));
    // A background that no longer exists must fall back to the plain surface.
    expect(find.byType(StudioBackground), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, Colors.transparent);
  });

  testWidgets('a real background image renders behind a transparent scaffold',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('videoader-bg-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final image = File('${directory.path}${Platform.pathSeparator}bg.png')
      ..writeAsBytesSync(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='));
    SharedPreferences.setMockInitialValues({
      'theme_background_image': image.path,
      'theme_background_blur': 12.0,
      'theme_background_veil': 0.7,
    });
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: VideoaderApp()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ImageFiltered), findsWidgets);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, Colors.transparent);
  });
}
