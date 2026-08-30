import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/mobile_settings_layout.dart';

void main() {
  test('settings layout normalization preserves platform fallback', () {
    expect(
      normalizeMobileSettingsLayout('', fallback: MobileSettingsLayout.modern),
      MobileSettingsLayout.modern,
    );
    expect(
      normalizeMobileSettingsLayout(
        'unexpected',
        fallback: MobileSettingsLayout.classic,
      ),
      MobileSettingsLayout.classic,
    );
    expect(
      normalizeMobileSettingsLayout(
        'modern',
        fallback: MobileSettingsLayout.classic,
      ),
      MobileSettingsLayout.modern,
    );
  });

  testWidgets('modern root stays scrollable in landscape', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileSettingsHome(
            selector: MobileSettingsLayoutSelector(
              layout: MobileSettingsLayout.modern,
              title: 'Settings layout',
              modernLabel: 'Modern',
              classicLabel: 'Classic',
              onChanged: (_) {},
            ),
            items: [
              for (final id in [
                'account',
                'general',
                'security',
                'network',
                'display',
                'about',
              ])
                MobileSettingsNavigationItem(
                  id: id,
                  title: id,
                  icon: Icons.settings,
                  onPressed: () {},
                ),
            ],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('mobile-settings-layout-selector')),
      findsOneWidget,
    );
    expect(find.byType(MobileSettingsNavigationChevron), findsWidgets);
    expect(find.byType(MobileSettingsRowTitle), findsWidgets);
    for (final icon in tester.widgetList<Icon>(
      find.byIcon(Icons.chevron_right),
    )) {
      expect(icon.size, 20);
    }
    await tester.scrollUntilVisible(
      find.byKey(const Key('mobile-settings-open-about')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('mobile-settings-open-about')), findsOneWidget);
    for (final icon in tester.widgetList<Icon>(
      find.byIcon(Icons.chevron_right),
    )) {
      expect(icon.size, 20);
    }
  });

  testWidgets('layout selector changes immediately', (tester) async {
    MobileSettingsLayout? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileSettingsLayoutSelector(
            layout: MobileSettingsLayout.modern,
            title: 'Settings layout',
            modernLabel: 'Modern',
            classicLabel: 'Classic',
            onChanged: (value) => selected = value,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Classic'));
    expect(selected, MobileSettingsLayout.classic);
  });

  testWidgets('category view renders groups and back action', (tester) async {
    var backPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileSettingsCategoryView(
            id: 'security',
            title: 'Security',
            onBack: () => backPressed = true,
            groups: const [
              MobileSettingsCategoryGroup(
                title: 'Trust',
                children: [ListTile(title: Text('Stored peer security'))],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Stored peer security'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-settings-category-back')));
    expect(backPressed, isTrue);
  });
}
