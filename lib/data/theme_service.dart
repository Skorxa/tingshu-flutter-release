import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../player/player_service.dart';
import 'settings_service.dart';

/// 动态主题:从当前播放有声书的封面提取 Material 3 配色。
/// - 监听 [PlayerService] 封面变化(按 URL 去重,避免 position 高频通知触发重算)
/// - 用内置 [ColorScheme.fromImageProvider] 同时生成明 / 暗两套,由夜间模式开关决定用哪套
/// - 无封面或取色失败时回退默认蓝色种子
class ThemeService extends ChangeNotifier {
  ThemeService._() {
    PlayerService.instance.addListener(_onPlayerChanged);
    SettingsService.instance.addListener(_onSettingsChanged);
  }
  static final ThemeService instance = ThemeService._();

  // 默认种子色:贴近原 TDesign 蓝,保证无播放时视觉连续
  static const Color _seed = Color(0xFF0052D9);

  ColorScheme _light = ColorScheme.fromSeed(seedColor: _seed);
  ColorScheme _dark = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
  );

  String _lastCoverUrl = '';
  int _seq = 0; // 请求序号:防止慢请求的过期结果覆盖新结果

  ColorScheme get light => _light;
  ColorScheme get dark => _dark;

  void _onPlayerChanged() {
    if (!SettingsService.instance.dynamicColor) return;
    final cover = PlayerService.instance.cover;
    if (cover == _lastCoverUrl) return;
    _lastCoverUrl = cover;
    unawaited(updateFromCover(cover));
  }

  void _onSettingsChanged() {
    if (SettingsService.instance.dynamicColor) {
      final cover = PlayerService.instance.cover;
      if (cover == _lastCoverUrl && cover.isNotEmpty) return;
      _lastCoverUrl = cover;
      unawaited(updateFromCover(cover));
    } else {
      _lastCoverUrl = '';
      _seq++;
      _applySeed();
    }
  }

  /// 从封面 URL 生成明暗配色;空 URL 或失败回退默认种子。
  Future<void> updateFromCover(String url) async {
    final mySeq = ++_seq;
    if (!SettingsService.instance.dynamicColor) {
      _applySeed();
      return;
    }
    if (url.isEmpty) {
      _applySeed();
      return;
    }
    try {
      final provider = _imageProvider(url);
      final light = await ColorScheme.fromImageProvider(provider: provider);
      final dark = await ColorScheme.fromImageProvider(
        provider: provider,
        brightness: Brightness.dark,
      );
      if (mySeq != _seq) return; // 已有更新的请求,丢弃过期结果
      _light = light;
      _dark = dark;
      notifyListeners();
    } catch (_) {
      if (mySeq != _seq) return;
      _applySeed();
    }
  }

  void _applySeed() {
    _light = ColorScheme.fromSeed(seedColor: _seed);
    _dark = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark);
    notifyListeners();
  }

  ImageProvider _imageProvider(String rawUrl) {
    var url = rawUrl.trim();
    if (url.startsWith('//')) url = 'https:$url';
    // 取色只需低分辨率:强制解码到 128px 宽,避免大封面全尺寸解码拖慢取色
    ImageProvider resolve(ImageProvider inner) =>
        ResizeImage(inner, width: 128, policy: ResizeImagePolicy.fit);
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return resolve(NetworkImage(url));
    }
    return resolve(FileImage(File(url)));
  }
}
