import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/services/editor_presets.dart';

void main() {
  test(
      'custom presets survive reloading and concurrent writes without leaking between editors',
      () async {
    SharedPreferences.setMockInitialValues({});
    final image = EditorPresetStore('image');
    await Future.wait([
      image.save('PNG', {'format': 'png', 'width': '1280'}),
      EditorPresetStore('image').save('JPEG', {'format': 'jpg'}),
    ]);
    final reloaded = await EditorPresetStore('image').load();
    expect(reloaded.keys, containsAll(['PNG', 'JPEG']));
    expect(reloaded['PNG']!['width'], '1280');
    expect(await EditorPresetStore('expert').load(), isEmpty);
    await image.delete('JPEG');
    expect((await image.load()).keys, ['PNG']);
    await expectLater(image.save('  ', {}), throwsFormatException);
    await image.save('After failure', {'rotation': 90});
    expect((await image.load()).keys, contains('After failure'));
  });
  test('damaged preset storage does not prevent opening an editor', () async {
    SharedPreferences.setMockInitialValues(
        {'editor_presets_v1_image': 'broken'});
    expect(await EditorPresetStore('image').load(), isEmpty);
  });
}
