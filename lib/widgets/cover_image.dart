import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/log_service.dart';

class CoverImage extends StatelessWidget {
  final String cover;
  final double width;
  final double height;
  final Widget fallback;
  final BoxFit fit;

  const CoverImage({
    super.key,
    required this.cover,
    required this.width,
    required this.height,
    required this.fallback,
    this.fit = BoxFit.cover,
  });

  // 诊断:同一失败目标只记一次日志,避免列表滚动反复刷屏
  static final Set<String> _loggedFailures = {};

  @override
  Widget build(BuildContext context) {
    final normalized = _normalizeCover(cover);
    if (normalized.isEmpty) return fallback;
    // 按显示尺寸 × 像素密度降采样解码,避免把原图(常 1000px)整张读进内存
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheW = (width * dpr).round();
    final cacheH = (height * dpr).round();
    if (_isNetwork(normalized)) {
      // 网络封面:磁盘缓存(CachedNetworkImage 自带) + 内存降采样 + 淡入
      return CachedNetworkImage(
        imageUrl: normalized,
        width: width,
        height: height,
        fit: fit,
        memCacheWidth: cacheW,
        memCacheHeight: cacheH,
        fadeInDuration: const Duration(milliseconds: 200),
        errorWidget: (_, url, error) => _onError(url, error, network: true),
      );
    }
    // 本地缓存封面:同样降采样;文件不存在时交给 errorBuilder 回退,无需提前同步 existsSync
    return Image.file(
      File(normalized),
      width: width,
      height: height,
      fit: fit,
      cacheWidth: cacheW,
      cacheHeight: cacheH,
      errorBuilder: (_, error, _) =>
          _onError(normalized, error, network: false),
    );
  }

  // 加载失败时记录诊断日志(去重)并回退到占位图
  Widget _onError(String target, Object error, {required bool network}) {
    if (_loggedFailures.add(target)) {
      LogService.instance.warning(
        'Cover',
        network ? '网络封面加载失败' : '本地封面加载失败',
        detail: '${network ? 'URL' : '路径'}: $target\n错误: $error',
      );
    }
    return fallback;
  }

  static bool _isNetwork(String value) {
    return value.startsWith('http://') || value.startsWith('https://');
  }

  static String _normalizeCover(String value) {
    var cover = value.trim();
    if (cover.isEmpty) return '';
    if (cover.startsWith('//')) cover = 'https:$cover';
    if (_isNetwork(cover)) {
      // 注意：不能用 Uri.encodeFull —— 会把已有的 %XX 二次编码成 %25XX，
      // 如番茄封面签名 %3D 变 %253D，CDN 直接 403。服务端 URL 已是合法转义，原样用之。
      // 仅当存在真正非法字符（空格/中文）时才做一次轻量规范化。
      final parsed = Uri.tryParse(cover);
      if (parsed == null) return cover;
      final normalized = parsed.toString();
      if (normalized.contains('%25') && !cover.contains('%25')) return cover;
      return normalized;
    }
    return cover;
  }
}
