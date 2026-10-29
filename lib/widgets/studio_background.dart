import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../providers/appearance_provider.dart';

/// Paints the optional custom background behind [child].
///
/// The image is only a backdrop: a theme-coloured veil of adjustable strength
/// sits on top of it, so panel text keeps the contrast it was designed with.
/// When no background is configured the child is returned untouched and the app
/// looks exactly like before.
class StudioBackground extends StatelessWidget {
  const StudioBackground(
      {super.key, required this.settings, required this.child});

  final AppearanceSettings settings;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    if (!settings.hasBackground) return child;

    final file = File(settings.backgroundImagePath!);
    // The path is stored as-is; a moved or deleted file must not crash the app.
    if (!file.existsSync()) return ColoredBox(color: surface, child: child);

    Widget image = Image.file(
      file,
      fit: BoxFit.cover,
      // Decode at screen resolution: a 4K/8K wallpaper would otherwise sit in
      // memory at full size for a blurred backdrop nobody inspects.
      cacheWidth:
          (MediaQuery.sizeOf(context).width *
                  MediaQuery.devicePixelRatioOf(context))
              .round(),
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => const SizedBox.expand(),
    );
    if (settings.backgroundBlur > 0.05) {
      final sigma = settings.backgroundBlur;
      image = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: image);
    }

    final veil = (settings.backgroundVeil * 255).round().clamp(0, 255).toInt();
    return Stack(fit: StackFit.expand, children: [
      ColoredBox(color: surface),
      image,
      ColoredBox(color: surface.withAlpha(veil)),
      child,
    ]);
  }
}
