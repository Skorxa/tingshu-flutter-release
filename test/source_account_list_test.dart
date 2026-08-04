import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tingshu_flutter/screens/source_config_screen.dart';
import 'package:tingshu_flutter/source/source_manager.dart';

void main() {
  testWidgets('account list shows an email and password field for every row', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'audio_sources': jsonEncode([
        {
          'id': 'dynamic-account-test',
          'name': '动态账号测试源',
          'apiVersion': 1,
          'configFields': [
            {
              'key': 'accounts',
              'label': '账号池',
              'type': 'account_list',
              'hint': '账号数量不限',
              'required': true,
            },
          ],
          'code': '',
          'enabled': true,
          'config': <String, dynamic>{},
        },
      ]),
    });
    await SourceManager.instance.init();

    await tester.pumpWidget(
      const MaterialApp(
        home: SourceConfigScreen(
          sourceId: 'dynamic-account-test',
          mode: SourceConfigMode.login,
        ),
      ),
    );

    expect(find.text('登录邮箱'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.tap(find.text('添加账号'));
    await tester.pump();

    expect(find.text('账号 2'), findsOneWidget);
    expect(find.text('登录邮箱'), findsNWidgets(2));
    expect(find.text('密码'), findsNWidgets(2));
    expect(find.byType(TextField), findsNWidgets(4));
  });
}
