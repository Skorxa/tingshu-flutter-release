import 'package:flutter/material.dart';

/// 会话级记忆:勾选"本次运行不再提示"后,本次应用运行内跳过。
bool _sessionConfirmed = false;

/// 第三方音源风险确认。
///
/// 音源是第三方 JavaScript,将在本机运行并可能向外部站点发起网络请求;
/// 导入本地/粘贴/链接音源或添加订阅前调用,返回 false 表示用户取消。
Future<bool> confirmThirdPartySourceRisk(BuildContext context) async {
  if (_sessionConfirmed) return true;
  var skipThisSession = false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('导入第三方音源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '音源是第三方 JavaScript 代码，将在本机运行并可能向外部站点发起网络请求。\n\n'
              '请仅导入来源可信的音源；来路不明的代码可能读取设备信息或外传数据。',
            ),
            CheckboxListTile(
              value: skipThisSession,
              onChanged: (value) =>
                  setDialogState(() => skipThisSession = value ?? false),
              title: const Text(
                '本次运行不再提示',
                style: TextStyle(fontSize: 14),
              ),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('仍然导入'),
          ),
        ],
      ),
    ),
  );
  final ok = confirmed ?? false;
  if (ok && skipThisSession) _sessionConfirmed = true;
  return ok;
}
