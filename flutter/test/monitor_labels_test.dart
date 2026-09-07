import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/monitor_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('numbers layout [idx2][idx3][idx1] without reordering capture IDs', () {
    const origins = [Offset(1920, 0), Offset(-1920, 0), Offset.zero];
    expect(monitorOrderForDisplays(origins), [1, 2, 0]);
    expect(monitorLabelsForDisplays(origins), ['3', '1', '2']);
    expect(origins, [
      const Offset(1920, 0),
      const Offset(-1920, 0),
      Offset.zero,
    ]);
  });

  test('reversed pair receives contiguous spatial numbers', () {
    const origins = [Offset(1920, 0), Offset.zero];
    expect(monitorOrderForDisplays(origins), [1, 0]);
    expect(monitorLabelsForDisplays(origins), ['2', '1']);
    expect(monitorLabelsForDisplays([Offset.zero]), ['1']);
  });

  test(
    'sorts equal x positions top-to-bottom, then capture index for clones',
    () {
      const origins = [
        Offset(0, 1080),
        Offset(0, -1080),
        Offset.zero,
        Offset.zero,
      ];
      expect(monitorOrderForDisplays(origins), [1, 2, 3, 0]);
      expect(monitorLabelsForDisplays(origins), ['4', '1', '2', '3']);
    },
  );

  test('horizontal order is unaffected by vertical offsets', () {
    expect(
      monitorOrderForDisplays([
        const Offset(1920, -300),
        const Offset(-1920, 400),
        Offset.zero,
      ]),
      [1, 2, 0],
    );
  });

  test('empty or invalid geometry has a deterministic fallback', () {
    expect(monitorOrderForDisplays([]), isEmpty);
    expect(monitorLabelsForDisplays([]), isEmpty);
    for (final invalid in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(
        monitorLabelsForDisplays([
          const Offset(1920, 0),
          Offset(invalid, 0),
          Offset.zero,
        ]),
        ['1', '2', '3'],
      );
    }
  });

  test('primary idx3 is toolbar 2 and leads automatic window allocation', () {
    final pi = PeerInfo()..platform = 'Windows';
    pi.displays.addAll([Display()..x = 1920, Display()..x = -1920, Display()]);
    pi.updatePrimaryDisplay(reportedPrimary: 2);
    expect(pi.primaryDisplay, 2);
    expect(pi.monitorLabel(pi.primaryDisplay), '2');
    expect(pi.monitorOrder, [1, 2, 0]);
    expect(pi.primaryFirstMonitorOrder, [2, 1, 0]);
    expect(
      pi.currentDisplay,
      0,
      reason: 'Metadata must not override a selected window',
    );

    // A reconnect refreshes primary metadata; it must not remain latched at 2.
    pi.updatePrimaryDisplay(reportedPrimary: 1);
    expect(pi.primaryDisplay, 1);
    expect(pi.primaryFirstMonitorOrder, [1, 2, 0]);
  });

  test(
    'Windows topology refresh uses origin, retaining the selected monitor',
    () {
      final pi = PeerInfo()
        ..platform = 'Windows'
        ..currentDisplay = 1;
      pi.displays.addAll([
        Display()..x = 1920,
        Display()..x = -1920,
        Display(),
      ]);
      pi.updatePrimaryDisplay();
      expect(pi.primaryDisplay, 2);
      expect(pi.currentDisplay, 1);
      pi.displays.value = [Display(), Display()..x = 1920];
      pi.updatePrimaryDisplay();
      expect(pi.primaryDisplay, 0);
      expect(pi.primaryFirstMonitorOrder, [0, 1]);
      expect(pi.currentDisplay, 1);
      pi.displays.clear();
      pi.updatePrimaryDisplay();
      expect(pi.primaryDisplay, kInvalidDisplayIndex);
      expect(pi.primaryFirstMonitorOrder, isEmpty);
    },
  );

  test('does not infer Linux primary or guess between mirrored origins', () {
    final pi = PeerInfo()..platform = 'Linux';
    pi.displays.addAll([Display(), Display()..x = 1920]);
    pi.updatePrimaryDisplay();
    expect(pi.primaryDisplay, kInvalidDisplayIndex);
    pi.updatePrimaryDisplay(reportedPrimary: 1);
    pi.updatePrimaryDisplay();
    expect(pi.primaryDisplay, 1);

    pi.platform = 'Windows';
    pi.displays.value = [Display(), Display()];
    pi.updatePrimaryDisplay();
    expect(pi.primaryDisplay, 1);
    pi.primaryDisplay = kInvalidDisplayIndex;
    pi.updatePrimaryDisplay();
    expect(pi.primaryDisplay, kInvalidDisplayIndex);
    expect(pi.primaryFirstMonitorOrder, [0, 1]);
  });
}
