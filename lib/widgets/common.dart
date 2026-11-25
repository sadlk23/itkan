import 'package:flutter/material.dart';

import '../services/inventory_store.dart';

void informUndo(BuildContext context, InventoryStore store, String message) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final changeId = store.history.firstOrNull?.id;
  final mode = store.isDemo;
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: changeId == null
          ? null
          : SnackBarAction(
              label: '되돌리기',
              onPressed: () async {
                try {
                  if (store.isDemo != mode) throw StateError('mode changed');
                  await store.undo(changeId);
                  if (messenger.mounted) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('변경을 되돌렸어요.')),
                    );
                  }
                } catch (_) {
                  if (messenger.mounted) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('이후 변경이 있어 바로 되돌릴 수 없어요. 변경 이력을 확인해주세요.'),
                      ),
                    );
                  }
                }
              },
            ),
    ),
  );
}

void inform(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = '확인하고 저장',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

class InfoBox extends StatelessWidget {
  const InfoBox(this.text, {super.key, this.icon = Icons.info_outline});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    decoration: BoxDecoration(
      color: const Color(0xFFEEF2E8),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: Color(0xFF52675D)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, height: 1.6)),
        ),
      ],
    ),
  );
}
