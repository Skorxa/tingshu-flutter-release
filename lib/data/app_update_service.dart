import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'log_service.dart';

class AppVersionInfo {
  final String versionName;
  final int versionCode;

  const AppVersionInfo({required this.versionName, required this.versionCode});
}

class AppUpdateInfo {
  final String versionName;
  final int versionCode;
  final bool force;
  final String changelog;
  final String sha256;
  final int size;
  final List<String> urls;
  final String publishedAt;

  const AppUpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.force,
    required this.changelog,
    required this.sha256,
    required this.size,
    required this.urls,
    required this.publishedAt,
  });
}

class DownloadedUpdate {
  final File file;
  final String sha256;
  final String sourceUrl;

  const DownloadedUpdate({
    required this.file,
    required this.sha256,
    required this.sourceUrl,
  });
}

class AppUpdateService {
  AppUpdateService._();
  static final instance = AppUpdateService._();

  static const List<String> githubAccelerators = [
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://github.chenc.dev/',
    'https://github.mxw.qzz.io/',
    'https://tvv.tw/',
    'https://gh.927223.xyz/',
  ];

  static const MethodChannel _channel = MethodChannel('tingshu/app_update');
  final Dio _dio = Dio();

  Future<AppVersionInfo> currentVersion() async {
    final ret = await _channel.invokeMapMethod<String, dynamic>(
      'getAppVersion',
    );
    if (ret == null) throw Exception('无法获取当前版本');
    return AppVersionInfo(
      versionName: '${ret['versionName'] ?? ''}'.trim(),
      versionCode: (ret['versionCode'] is num)
          ? (ret['versionCode'] as num).toInt()
          : int.tryParse('${ret['versionCode']}') ?? 0,
    );
  }

  Future<AppUpdateInfo> check(String manifestUrl) async {
    final normalized = manifestUrl.trim();
    if (normalized.isEmpty) throw Exception('更新清单地址为空');
    LogService.instance.info('Update', '开始检查软件更新', detail: '清单: $normalized');
    final response = await _fetchManifest(normalized);
    final raw = response.data;
    final dynamic data;
    if (raw is String) {
      data = jsonDecode(raw);
    } else {
      data = raw;
    }
    if (data is! Map) {
      throw Exception('更新清单格式错误');
    }
    final map = Map<String, dynamic>.from(data);
    final versionName = '${map['versionName'] ?? ''}'.trim();
    final versionCode = (map['versionCode'] is num)
        ? (map['versionCode'] as num).toInt()
        : int.tryParse('${map['versionCode']}') ?? 0;
    final sha = '${map['sha256'] ?? ''}'.trim().toLowerCase();
    final size = (map['size'] is num)
        ? (map['size'] as num).toInt()
        : int.tryParse('${map['size']}') ?? 0;
    final rawUrls = switch (map['urls']) {
      final List list => list,
      _ =>
        (map['downloadUrls'] is List) ? map['downloadUrls'] as List : const [],
    };
    final urls = _expandUrls(
      rawUrls
          .map((value) => _resolveUrl(normalized, '$value'))
          .where((value) => value.isNotEmpty),
    );
    if (versionName.isEmpty || versionCode <= 0) {
      throw Exception('更新清单缺少有效版本号');
    }
    if (urls.isEmpty) throw Exception('更新清单缺少下载地址');
    if (sha.isEmpty) throw Exception('更新清单缺少 sha256');
    final info = AppUpdateInfo(
      versionName: versionName,
      versionCode: versionCode,
      force: map['force'] == true,
      changelog: '${map['changelog'] ?? map['releaseNotes'] ?? ''}'.trim(),
      sha256: sha,
      size: size,
      urls: urls,
      publishedAt: '${map['publishedAt'] ?? map['published_at'] ?? ''}'.trim(),
    );
    LogService.instance.info(
      'Update',
      '软件更新清单解析完成',
      detail:
          '版本: ${info.versionName} (${info.versionCode})\n地址数: ${info.urls.length}\n内置加速线路:\n${githubAccelerators.join('\n')}\n强制更新: ${info.force ? '是' : '否'}',
    );
    return info;
  }

  Future<DownloadedUpdate> download(
    AppUpdateInfo info, {
    void Function(double progress, String url, int index)? onProgress,
  }) async {
    final dir = await _updateDir();
    final target = File(path.join(dir.path, 'update-${info.versionCode}.apk'));
    final temp = File('${target.path}.tmp');
    if (temp.existsSync()) {
      try {
        await temp.delete();
      } catch (_) {}
    }

    Object? lastError;
    for (var i = 0; i < info.urls.length; i++) {
      final url = info.urls[i];
      try {
        LogService.instance.info(
          'Update',
          '开始下载更新包',
          detail:
              '版本: ${info.versionName}\n镜像: ${i + 1}/${info.urls.length}\nURL: $url',
        );
        await _dio.download(
          url,
          temp.path,
          onReceiveProgress: (received, total) {
            final base = total > 0
                ? received / total
                : (info.size > 0 ? received / info.size : 0.0);
            onProgress?.call(base.clamp(0.0, 1.0), url, i);
          },
          options: Options(
            receiveTimeout: const Duration(minutes: 10),
            sendTimeout: const Duration(seconds: 30),
          ),
        );
        if (!temp.existsSync()) throw Exception('下载文件不存在');
        final digest = (await sha256.bind(temp.openRead()).first)
            .toString()
            .toLowerCase();
        if (digest != info.sha256) {
          throw Exception('sha256 校验失败');
        }
        if (target.existsSync()) {
          try {
            await target.delete();
          } catch (_) {}
        }
        await temp.rename(target.path);
        LogService.instance.info(
          'Update',
          '更新包下载完成',
          detail:
              '版本: ${info.versionName}\n路径: ${target.path}\nsha256: $digest',
        );
        return DownloadedUpdate(file: target, sha256: digest, sourceUrl: url);
      } catch (e, stack) {
        lastError = e;
        LogService.instance.error(
          'Update',
          '更新包下载失败，尝试下一镜像',
          error: e,
          stack: stack,
        );
        if (temp.existsSync()) {
          try {
            await temp.delete();
          } catch (_) {}
        }
      }
    }
    throw Exception('全部更新地址下载失败: ${lastError ?? '未知错误'}');
  }

  Future<void> installApk(String filePath) async {
    final normalized = filePath.trim();
    if (normalized.isEmpty) throw Exception('APK 路径为空');
    await _channel.invokeMethod('installApk', {'path': normalized});
    LogService.instance.info(
      'Update',
      '已调起 APK 安装器',
      detail: '路径: $normalized',
    );
  }

  Future<Directory> _updateDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(path.join(base.path, 'updates'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<Response<dynamic>> _fetchManifest(String manifestUrl) async {
    final urls = _expandUrls([manifestUrl]);
    Object? lastError;
    for (var i = 0; i < urls.length; i++) {
      final url = urls[i];
      try {
        LogService.instance.info(
          'Update',
          '尝试读取更新清单',
          detail: '线路: ${i + 1}/${urls.length}\nURL: $url',
        );
        return await _dio.get(
          url,
          options: Options(
            responseType: ResponseType.plain,
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
      } catch (e, stack) {
        lastError = e;
        LogService.instance.error(
          'Update',
          '更新清单读取失败，尝试下一线路',
          error: e,
          stack: stack,
        );
      }
    }
    throw Exception('全部更新清单线路读取失败: ${lastError ?? '未知错误'}');
  }

  String _resolveUrl(String manifestUrl, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) return uri.toString();
    final base = Uri.tryParse(manifestUrl);
    if (base == null) return trimmed;
    return base.resolve(trimmed).toString();
  }

  List<String> _expandUrls(Iterable<String> urls) {
    final result = <String>[];
    final seen = <String>{};
    for (final raw in urls) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final expanded = _githubAcceleratedUrls(trimmed);
      for (final url in expanded) {
        if (seen.add(url)) result.add(url);
      }
    }
    return result;
  }

  List<String> _githubAcceleratedUrls(String url) {
    if (!_canAccelerateGithubUrl(url)) return [url];
    return [
      for (final accelerator in githubAccelerators)
        _joinProxyUrl(accelerator, url),
      url,
    ];
  }

  bool _canAccelerateGithubUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return false;
    final host = uri.host.toLowerCase();
    return host == 'github.com' || host == 'raw.githubusercontent.com';
  }

  String _joinProxyUrl(String proxy, String url) {
    final normalizedProxy = proxy.endsWith('/') ? proxy : '$proxy/';
    return '$normalizedProxy$url';
  }
}
