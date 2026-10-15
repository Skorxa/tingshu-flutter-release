import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu_flutter/data/aliyun_pan_service.dart';
import 'package:tingshu_flutter/data/pan115_service.dart';

/// 115 网盘 / 阿里云盘两个新内置网盘的纯函数测试。
///
/// 只覆盖不依赖网络与实例状态的部分(条目映射、命名解析、排序、请求头变体、
/// 凭据摘要、登录态解析)。真实接口字段名仍需按抓包核对,见 docs/网盘接入说明.md。
void main() {
  group('Pan115Service 纯函数', () {
    test('音频与封面扩展名识别', () {
      expect(Pan115Service.isAudioName('第01集.mp3'), isTrue);
      expect(Pan115Service.isAudioName('a.M4B'), isTrue);
      expect(Pan115Service.isAudioName('cover.jpg'), isFalse);
      expect(Pan115Service.isCoverName('cover.jpg'), isTrue);
      expect(Pan115Service.isCoverName('Cover_1.png'), isTrue);
      expect(Pan115Service.isCoverName('cover.txt'), isFalse);
      expect(Pan115Service.isCoverName('封面.jpg'), isFalse);
    });

    test('文件夹名 书名_作者_演播者 解析', () {
      final meta = Pan115Service.parseFolderName('某本书_某作者_某演播');
      expect(meta, isNotNull);
      expect(meta!.title, '某本书');
      expect(meta.author, '某作者');
      expect(meta.narrator, '某演播');
      // 三段以上:后面全部并进演播者
      expect(Pan115Service.parseFolderName('书_作者_演播_补充')!.narrator, '演播_补充');
      // 不足三段返回 null,由调用方回落目录名
      expect(Pan115Service.parseFolderName('某本书_某作者'), isNull);
    });

    test('itemFromJson 兼容字段别名', () {
      final item = Pan115Service.itemFromJson({
        'fid': 'f1',
        'pc': 'pc1',
        'n': '第01集.mp3',
        's': '1234',
        'ico': 'https://cdn/thumb.jpg',
      });
      expect(item.fid, 'f1');
      expect(item.pickCode, 'pc1');
      expect(item.name, '第01集.mp3');
      expect(item.size, 1234);
      expect(item.thumb, 'https://cdn/thumb.jpg');
      expect(item.isDirectory, isFalse);

      final dir = Pan115Service.itemFromJson({
        'fid': 'f2',
        'n': '某本书_某作者_某演播',
        't': 'folder',
      });
      expect(dir.isDirectory, isTrue);
    });

    test('chapterToken 优先 pick_code,缺失回落 id:<fid>', () {
      const withCode = Pan115Item(
        fid: 'f1',
        pickCode: 'pc1',
        name: 'a.mp3',
        isDirectory: false,
      );
      const noCode = Pan115Item(
        fid: 'f2',
        name: 'b.mp3',
        isDirectory: false,
      );
      expect(Pan115Service.chapterIdFor(withCode), 'pan115:pc1');
      expect(Pan115Service.chapterIdFor(noCode), 'pan115:id:f2');
      expect(
        Pan115Service.chapterIdFor(withCode).startsWith(
          Pan115Service.chapterPrefix,
        ),
        isTrue,
      );
    });

    test('自然序排序:数字按数值比较,目录优先', () {
      expect(Pan115Service.naturalCompare('第2集.mp3', '第10集.mp3'), isNegative);
      expect(Pan115Service.naturalCompare('第10集.mp3', '第2集.mp3'), isPositive);
      expect(Pan115Service.naturalCompare('a.mp3', 'a.mp3'), 0);

      const dir = Pan115Item(fid: 'd', name: '第99章', isDirectory: true);
      const file = Pan115Item(fid: 'f', name: '第01集.mp3', isDirectory: false);
      expect(Pan115Service.compareItems(dir, file), isNegative);
    });

    test('播放头变体逐级摘除凭据', () {
      const cookie = 'UID=u; CID=c; SEID=s';
      final base = Pan115Service.playHeadersFor(cookie);
      expect(base['Cookie'], cookie);
      expect(base['Referer'], isNotEmpty);

      final v1 = Pan115Service.headerVariantHeaders(base, 1);
      expect(v1.containsKey('Cookie'), isFalse);
      expect(v1.containsKey('User-Agent'), isTrue);
      expect(v1['Referer'], isNotEmpty);

      final v2 = Pan115Service.headerVariantHeaders(base, 2);
      expect(v2.containsKey('Cookie'), isFalse);
      expect(v2.containsKey('Referer'), isFalse);
      expect(v2.containsKey('User-Agent'), isTrue);
    });

    test('默认内置 AppID 为 100195135', () {
      expect(Pan115Service.defaultAppId, '100195135');
      expect(Pan115Service.instance.appId, isNotEmpty);
    });

    test('PKCE 生成校验', () {
      final verifier = Pan115Service.genVerifier();
      expect(verifier.length, 64);
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier), isTrue);

      final challenge = Pan115Service.genChallenge(verifier);
      expect(challenge.isNotEmpty, isTrue);
      expect(challenge.contains('='), isFalse);
      expect(challenge.contains('+'), isFalse);
      expect(challenge.contains('/'), isFalse);
    });

    test('itemFromJson 兼容官方开放平台字段与类型', () {
      final openApiItem = Pan115Service.itemFromJson({
        'file_id': 'f_open_1',
        'pick_code': 'pc_open_1',
        'file_name': '第一章 启程.m4a',
        'file_size': 9876543,
        'thumb': 'https://115.com/thumb/1.png',
        'file_category': 1,
      });
      expect(openApiItem.fid, 'f_open_1');
      expect(openApiItem.pickCode, 'pc_open_1');
      expect(openApiItem.name, '第一章 启程.m4a');
      expect(openApiItem.size, 9876543);
      expect(openApiItem.thumb, 'https://115.com/thumb/1.png');
      expect(openApiItem.isDirectory, isFalse);

      final openApiFolder = Pan115Service.itemFromJson({
        'file_id': 'dir_open_1',
        'file_name': '有声书大合集_主播A_演播B',
        'file_category': 0,
      });
      expect(openApiFolder.isDirectory, isTrue);
      expect(openApiFolder.fid, 'dir_open_1');
    });

    test('播放头支持 Bearer Token 并在变体 1 去除凭据', () {
      const token = 'test_access_token_12345';
      final headers = Pan115Service.playHeadersFor(token);
      expect(headers['Authorization'], 'Bearer $token');
      expect(headers['User-Agent'], isNotEmpty);
      expect(headers['Referer'], isNotEmpty);

      final v1 = Pan115Service.headerVariantHeaders(headers, 1);
      expect(v1.containsKey('Authorization'), isFalse);
      expect(v1.containsKey('User-Agent'), isTrue);
      expect(v1['Referer'], isNotEmpty);

      final v2 = Pan115Service.headerVariantHeaders(headers, 2);
      expect(v2.containsKey('Authorization'), isFalse);
      expect(v2.containsKey('Referer'), isFalse);
      expect(v2.containsKey('User-Agent'), isTrue);
    });

    test('tokenSummary 脱敏安全校验', () {
      expect(Pan115Service.tokenSummary(''), '(无)');
      final summary = Pan115Service.tokenSummary('abcdef1234567890uvwxyz');
      expect(summary.contains('abcdef1234567890uvwxyz'), isFalse);
      expect(summary.startsWith('abcd...'), isTrue);
      expect(summary.contains('长度 22'), isTrue);
    });

    test('cookieSummary 只输出字段名,不泄漏值', () {
      final summary = Pan115Service.cookieSummary('UID=secret1; CID=secret2');
      expect(summary, 'UID, CID');
      expect(summary.contains('secret'), isFalse);
      expect(Pan115Service.cookieSummary(''), '(无)');
    });
  });

  group('AliyunPanService 纯函数', () {
    test('音频与封面扩展名识别', () {
      expect(AliyunPanService.isAudioName('第01集.flac'), isTrue);
      expect(AliyunPanService.isCoverName('cover.webp'), isTrue);
      expect(AliyunPanService.isCoverName('第01集.mp3'), isFalse);
    });

    test('文件夹名解析与 115 一致', () {
      final meta = AliyunPanService.parseFolderName('书_作者_演播');
      expect(meta!.title, '书');
      expect(meta.author, '作者');
      expect(meta.narrator, '演播');
      expect(AliyunPanService.parseFolderName('只有名字'), isNull);
    });

    test('itemFromJson:type=folder 视为目录,字段别名兼容', () {
      final folder = AliyunPanService.itemFromJson({
        'file_id': 'root1',
        'name': '某本书_某作者_某演播',
        'type': 'folder',
      });
      expect(folder.isDirectory, isTrue);
      expect(folder.fileId, 'root1');

      final audio = AliyunPanService.itemFromJson({
        'fileId': 'f9',
        'name': '第01集.mp3',
        'size': 1024,
        'thumbnail': 'https://cdn/t.jpg',
      });
      expect(audio.isDirectory, isFalse);
      expect(audio.fileId, 'f9');
      expect(audio.size, 1024);
      expect(audio.thumb, 'https://cdn/t.jpg');

      expect(
        AliyunPanService.chapterIdFor(audio),
        'aliyun:f9',
      );
      expect(
        AliyunPanService.chapterIdFor(audio).startsWith(
          AliyunPanService.chapterPrefix,
        ),
        isTrue,
      );
    });

    test('播放头变体:变体 1 去掉 Authorization,变体 2 仅 UA', () {
      final base = AliyunPanService.playHeadersFor('token-abc');
      expect(base['Authorization'], 'Bearer token-abc');

      final v1 = AliyunPanService.headerVariantHeaders(base, 1);
      expect(v1.containsKey('Authorization'), isFalse);
      expect(v1.containsKey('User-Agent'), isTrue);

      final v2 = AliyunPanService.headerVariantHeaders(base, 2);
      expect(v2.keys, ['User-Agent']);
      expect(v2.containsKey('Authorization'), isFalse);
      expect(v2.containsKey('Referer'), isFalse);
    });

    test('parseWebLoginToken 解析常见形态', () {
      final raw = jsonEncode({
        'access_token': 'at',
        'refresh_token': 'rt',
        'default_drive_id': 'drv',
        'expires_in': 7200,
      });
      final map = AliyunPanService.parseWebLoginToken(raw);
      expect(map['access_token'], 'at');
      expect(map['refresh_token'], 'rt');
      expect(map['drive_id'], 'drv');
      expect(map['default_drive_id'], 'drv');

      // 被 URL 编码过的登录态也要能解析
      final encoded = AliyunPanService.parseWebLoginToken(
        Uri.encodeComponent(raw),
      );
      expect(encoded['access_token'], 'at');
    });

    test('parseWebLoginToken 对非法输入给出可读错误', () {
      expect(
        () => AliyunPanService.parseWebLoginToken(''),
        throwsA(isA<Exception>()),
      );
      expect(
        () => AliyunPanService.parseWebLoginToken('不是 JSON'),
        throwsA(isA<Exception>()),
      );
      expect(
        () => AliyunPanService.parseWebLoginToken('{"refresh_token":"rt"}'),
        throwsA(isA<Exception>()),
      );
    });

    test('tokenSummary 不泄漏原文', () {
      final summary = AliyunPanService.tokenSummary('a.b.c');
      expect(summary.contains('a.b.c'), isFalse);
      expect(summary, contains('长度'));
      expect(AliyunPanService.tokenSummary(''), '(无)');
    });
  });
}
