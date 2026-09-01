// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'queue_tab.dart';

/// Exports the active (non-completed) queue as a portable JSON file and opens
/// the system share sheet so it can be moved to another device.
Future<void> _shareQueueTransfer(
  BuildContext context,
  WidgetRef ref,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final items = ref.read(downloadQueueProvider).items
      .where((item) => item.status != DownloadStatus.completed)
      .toList(growable: false);
  if (items.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Nothing to share — the queue is empty')),
    );
    return;
  }
  try {
    final path = await QueueTransferService.exportAndShare(
      items,
      exportName: 'spotiflac-queue',
    );
    if (path == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Nothing to share — the queue is empty')),
      );
    }
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not share queue: $e')),
    );
  }
}

/// Picks a SpotiFLAC queue export JSON file and re-queues its tracks with a
/// confirmation message.
Future<void> _importQueueTransfer(
  BuildContext context,
  WidgetRef ref,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final opened = await QueueTransferService.pickAndImport();
  if (opened == null) return;
  final tracks = QueueTransferService.tracksFromItems(opened);
  if (tracks.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('No tracks found in this queue file')),
    );
    return;
  }
  ref.read(downloadQueueProvider.notifier).addMultipleToQueue(
    tracks,
    opened.first.service,
  );
  messenger.showSnackBar(
    SnackBar(
      content: Text('Imported ${tracks.length} track(s) into the queue'),
    ),
  );
}
