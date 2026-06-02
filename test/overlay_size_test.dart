import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/ui/overlay/overlay_size.dart';

void main() {
  group('OverlaySizing.select', () {
    test('locked and not granted → full', () {
      expect(
        OverlaySizing.select(locked: true, granted: false),
        OverlaySize.full,
      );
    });

    test('plain timed grant → banner', () {
      expect(
        OverlaySizing.select(locked: false, granted: true),
        OverlaySize.banner,
      );
    });

    test('per-app grant → mini', () {
      expect(
        OverlaySizing.select(
            locked: false, granted: true, perAppGrant: true),
        OverlaySize.mini,
      );
    });

    test('fold-to-corner full grant → mini', () {
      expect(
        OverlaySizing.select(
            locked: false, granted: true, foldToCorner: true),
        OverlaySize.mini,
      );
    });

    test('granted wins over locked when both somehow set', () {
      // A grant during the lockdown window should not show the full block.
      expect(
        OverlaySizing.select(locked: true, granted: true),
        OverlaySize.banner,
      );
    });

    test('idle (no lock, no grant) → banner default', () {
      expect(
        OverlaySizing.select(locked: false, granted: false),
        OverlaySize.banner,
      );
    });
  });
}
