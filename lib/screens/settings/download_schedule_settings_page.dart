import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/download_schedule_settings_provider.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Settings → Download → Download scheduling.
///
/// Lets users restrict auto-starting downloads to a time window (for example a
/// nightly window). When the window closes, the queue pauses; when it reopens,
/// the queue resumes automatically.
class DownloadScheduleSettingsPage extends ConsumerWidget {
  const DownloadScheduleSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(downloadScheduleSettingsProvider);
    final notifier = ref.read(downloadScheduleSettingsProvider.notifier);

    return CustomScrollView(
      slivers: [
        AppSliverHeader.page(title: 'Download scheduling'),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              context.tokens.pagePadding,
              context.tokens.pagePadding * 0.5,
              context.tokens.pagePadding,
              context.tokens.pagePadding * 0.5,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsGroup(
                  children: [
                    SettingsSwitchItem(
                      icon: Icons.schedule_outlined,
                      title: 'Scheduled downloads',
                      subtitle:
                          'Pause the queue outside the window and resume it automatically',
                      value: settings.enabled,
                      onChanged: notifier.setEnabled,
                    ),
                    _TimeItem(
                      icon: Icons.wb_twilight_outlined,
                      title: 'Start',
                      subtitle: 'Downloads may begin at this time',
                      label: settings.startLabel,
                      enabled: settings.enabled,
                      onChanged: (value) => notifier.setStartMinute(value),
                    ),
                    _TimeItem(
                      icon: Icons.dark_mode_outlined,
                      title: 'End',
                      subtitle: 'Wait until this time before resuming',
                      label: settings.endLabel,
                      enabled: settings.enabled,
                      onChanged: (value) => notifier.setEndMinute(value),
                      showDivider: false,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'A window that ends earlier than it starts crosses midnight, '
                  'e.g. 22:00 → 07:00.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TimeItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String label;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final bool showDivider;

  const _TimeItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.label,
    required this.enabled,
    required this.onChanged,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: enabled ? () => _pickTime(context) : null,
      showDivider: showDivider,
    );
  }

  Future<void> _pickTime(BuildContext context) async {
    final initial = _parseMinute(label);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
    );
    if (picked == null) return;
    onChanged(picked.hour * 60 + picked.minute);
  }

  int _parseMinute(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return 0;
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = int.tryParse(parts[1]) ?? 0;
    return hour * 60 + minute;
  }
}
