import 'package:flutter/material.dart';

enum MobileSettingsLayout { modern, classic }

MobileSettingsLayout normalizeMobileSettingsLayout(
  String value, {
  required MobileSettingsLayout fallback,
}) {
  return switch (value) {
    'modern' => MobileSettingsLayout.modern,
    'classic' => MobileSettingsLayout.classic,
    _ => fallback,
  };
}

String mobileSettingsLayoutOption(MobileSettingsLayout layout) => layout.name;

class MobileSettingsNavigationChevron extends StatelessWidget {
  const MobileSettingsNavigationChevron({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 32,
      height: 32,
      child: Icon(Icons.chevron_right, size: 20),
    );
  }
}

class MobileSettingsRowTitle extends StatelessWidget {
  const MobileSettingsRowTitle({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      style: Theme.of(context).textTheme.bodyLarge,
      child: child,
    );
  }
}

class MobileSettingsRowSubtitle extends StatelessWidget {
  const MobileSettingsRowSubtitle({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      style: Theme.of(context).textTheme.bodySmall,
      child: child,
    );
  }
}

class MobileSettingsLayoutSelector extends StatelessWidget {
  const MobileSettingsLayoutSelector({
    super.key,
    required this.layout,
    required this.title,
    required this.modernLabel,
    required this.classicLabel,
    required this.onChanged,
  });

  final MobileSettingsLayout layout;
  final String title;
  final String modernLabel;
  final String classicLabel;
  final ValueChanged<MobileSettingsLayout>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<MobileSettingsLayout>(
            key: const Key('mobile-settings-layout-selector'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: MobileSettingsLayout.modern,
                label: Text(modernLabel),
                icon: const Icon(Icons.view_agenda_outlined),
              ),
              ButtonSegment(
                value: MobileSettingsLayout.classic,
                label: Text(classicLabel),
                icon: const Icon(Icons.view_list_outlined),
              ),
            ],
            selected: {layout},
            onSelectionChanged: onChanged == null
                ? null
                : (selection) {
                    if (selection.isNotEmpty) {
                      onChanged!(selection.first);
                    }
                  },
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }
}

class MobileSettingsNavigationItem {
  const MobileSettingsNavigationItem({
    required this.id,
    required this.title,
    required this.icon,
    required this.onPressed,
    this.subtitle,
  });

  final String id;
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onPressed;
}

class MobileSettingsHome extends StatelessWidget {
  const MobileSettingsHome({
    super.key,
    required this.selector,
    required this.items,
  });

  final Widget selector;
  final List<MobileSettingsNavigationItem> items;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      key: const Key('mobile-settings-modern-root'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      physics: const ClampingScrollPhysics(),
      itemCount: items.length + 1,
      separatorBuilder: (context, index) =>
          index == 0 ? const SizedBox(height: 12) : const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) return selector;
        final item = items[index - 1];
        return ListTile(
          key: Key('mobile-settings-open-${item.id}'),
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          leading: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(item.icon),
          ),
          title: MobileSettingsRowTitle(child: Text(item.title)),
          subtitle: item.subtitle == null
              ? null
              : MobileSettingsRowSubtitle(child: Text(item.subtitle!)),
          trailing: const MobileSettingsNavigationChevron(),
          onTap: item.onPressed,
        );
      },
    );
  }
}

class MobileSettingsCategoryGroup {
  const MobileSettingsCategoryGroup({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;
}

class MobileSettingsCategoryView extends StatelessWidget {
  const MobileSettingsCategoryView({
    super.key,
    required this.id,
    required this.title,
    required this.onBack,
    required this.groups,
  });

  final String id;
  final String title;
  final VoidCallback onBack;
  final List<MobileSettingsCategoryGroup> groups;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: Key('mobile-settings-category-$id'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      physics: const ClampingScrollPhysics(),
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('mobile-settings-category-back'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) ...[
          if (groupIndex > 0) const SizedBox(height: 16),
          if (groups[groupIndex].title.isNotEmpty) ...[
            Text(
              groups[groupIndex].title,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
          ],
          for (
            var childIndex = 0;
            childIndex < groups[groupIndex].children.length;
            childIndex++
          ) ...[
            if (childIndex > 0) const Divider(height: 1),
            groups[groupIndex].children[childIndex],
          ],
        ],
      ],
    );
  }
}
