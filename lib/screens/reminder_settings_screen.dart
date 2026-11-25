import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/inventory_store.dart';
import '../services/reminder_service.dart';
import '../widgets/common.dart';

class ReminderSettingsScreen extends StatefulWidget {
  const ReminderSettingsScreen({super.key, required this.store});
  final InventoryStore store;
  @override
  State<ReminderSettingsScreen> createState() => _ReminderSettingsScreenState();
}

class _ReminderSettingsScreenState extends State<ReminderSettingsScreen>
    with WidgetsBindingObserver {
  bool enabled = false, allowed = false, busy = true;
  bool scheduleFailed = false;
  int days = 3;
  TimeOfDay time = const TimeOfDay(hour: 9, minute: 0);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refreshPermission();
  }

  Future<void> refreshPermission() async {
    try {
      final value = await ReminderService.channel.invokeMethod<bool>(
        'notificationPermission',
      );
      if (mounted) setState(() => allowed = value ?? false);
    } catch (_) {
      if (mounted) setState(() => allowed = false);
    }
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      bool permission = false;
      try {
        permission =
            await ReminderService.channel.invokeMethod<bool>(
              'notificationPermission',
            ) ??
            false;
      } catch (_) {}
      if (mounted) {
        setState(() {
          enabled = p.getBool('reminders_enabled') ?? false;
          final savedDays = p.getInt('reminders_days');
          days = [1, 3, 7].contains(savedDays) ? savedDays! : 3;
          time = TimeOfDay(
            hour: (p.getInt('reminders_hour') ?? 9).clamp(0, 23),
            minute: (p.getInt('reminders_minute') ?? 0).clamp(0, 59),
          );
          allowed = permission;
          busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => busy = false);
        inform(context, '저장된 알림 설정을 읽지 못했어요. 화면을 다시 열어주세요.');
      }
    }
  }

  Future<void> save() async {
    scheduleFailed = true;
    final p = await SharedPreferences.getInstance();
    await p.setBool('reminders_enabled', enabled);
    await p.setInt('reminders_days', days);
    await p.setInt('reminders_hour', time.hour);
    await p.setInt('reminders_minute', time.minute);
    await ReminderService(widget.store).sync(reportErrors: true);
    scheduleFailed = false;
  }

  Future<void> saveChange(VoidCallback change) async {
    setState(() {
      busy = true;
      change();
    });
    try {
      await save();
    } catch (_) {
      if (mounted) inform(context, '알림 예약을 완료하지 못했어요. 설정을 확인하고 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('알림·기기 권한')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('소비기한 알림'),
          subtitle: Text(allowed ? '기기 알림 허용됨' : '알림 권한이 없어도 앱 안의 날짜 표시는 유지돼요'),
          value: enabled,
          onChanged: busy
              ? null
              : (v) async {
                  setState(() => busy = true);
                  try {
                    if (v) {
                      allowed =
                          await ReminderService.channel.invokeMethod<bool>(
                            'requestNotificationPermission',
                          ) ??
                          false;
                    }
                    enabled = v && allowed;
                    await save();
                    if (context.mounted && !allowed && v) {
                      inform(context, '기기 설정에서 잇칸 알림과 소비기한 알림을 켜주세요.');
                    }
                  } catch (_) {
                    if (context.mounted) {
                      inform(context, '이 기기에서는 알림을 설정하지 못했어요.');
                    }
                  }
                  if (mounted) setState(() => busy = false);
                },
        ),
        DropdownButtonFormField<int>(
          key: ValueKey(days),
          initialValue: days,
          decoration: const InputDecoration(labelText: '며칠 전부터 알려드릴까요?'),
          items: [1, 3, 7]
              .map((v) => DropdownMenuItem(value: v, child: Text('$v일 전')))
              .toList(),
          onChanged: busy ? null : (v) => saveChange(() => days = v!),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('알림 시각'),
          trailing: Text(time.format(context)),
          onTap: busy
              ? null
              : () async {
                  final selected = await showTimePicker(
                    context: context,
                    initialTime: time,
                  );
                  if (selected != null && mounted) {
                    await saveChange(() => time = selected);
                  }
                },
        ),
        const InfoBox(
          '등록한 소비기한을 기준으로 선택한 며칠 전부터 기한 다음 날까지 알려드려요. 같은 날의 재료는 한 알림으로 모으고 추정 날짜를 표시해요. 절전 설정에 따라 도착이 늦어질 수 있어요.',
        ),
        if (scheduleFailed)
          TextButton.icon(
            onPressed: busy ? null : () => saveChange(() {}),
            icon: const Icon(Icons.refresh),
            label: const Text('알림 예약 다시 시도'),
          ),
        OutlinedButton(
          onPressed: () async {
            try {
              final ok = await ReminderService.channel.invokeMethod<bool>(
                'showTestNotification',
              );
              if (context.mounted) {
                inform(
                  context,
                  ok == true
                      ? '기기 알림창을 확인해주세요.'
                      : '기기 설정에서 잇칸 알림과 소비기한 알림을 켜주세요.',
                );
              }
            } catch (_) {
              if (context.mounted) inform(context, '알림을 표시하지 못했어요.');
            }
          },
          child: const Text('테스트 알림 보내기'),
        ),
        const Divider(),
        const Text(
          '마이크 권한은 음성 입력을 누를 때 요청해요. 영수증 사진은 기기에서 인식하고 인식이 끝나면 앱의 임시 사진을 바로 삭제해요. 재료에 첨부한 사진은 앱에 복사해 보관하며 갤러리 원본은 그대로 유지돼요.',
        ),
        TextButton(
          onPressed: () async {
            try {
              await ReminderService.channel.invokeMethod<void>(
                'openAppSettings',
              );
            } catch (_) {
              if (context.mounted) inform(context, '운영체제 앱 설정에서 권한을 확인해주세요.');
            }
          },
          child: const Text('기기 앱 설정 열기'),
        ),
      ],
    ),
  );
}
