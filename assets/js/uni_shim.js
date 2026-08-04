// uni 垫片 + 音源运行时(在 QuickJS 中执行)
// flutter_js 已提供: sendMessage / console / setTimeout / JSON / Promise
// 本文件提供音源脚本依赖的 uni.* 能力,并把音源调用桥接给 Dart。

var __httpSeq = 0;
var __httpCbs = {};
var __cryptoSeq = 0;
var __cryptoCbs = {};
var __store = {};
var __sourceConfigs = {};
var __currentCallSourceId = '';

if (typeof atob !== 'function') {
  var atob = function (input) {
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
    var str = String(input || '').replace(/=+$/, '');
    var output = '';
    if (str.length % 4 === 1) throw new Error('InvalidCharacterError');
    for (var bc = 0, bs = 0, buffer, idx = 0; (buffer = str.charAt(idx++));) {
      buffer = chars.indexOf(buffer);
      if (buffer < 0) continue;
      bs = bc % 4 ? bs * 64 + buffer : buffer;
      if (bc++ % 4) output += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6)));
    }
    try {
      return decodeURIComponent(escape(output));
    } catch (e) {
      return output;
    }
  };
}

var uni = {
  // 镜像 uni.request: 通过 http 通道交给 Dart(dio)执行,完成后回调 success/fail
  request: function (opts) {
    opts = opts || {};
    var id = ++__httpSeq;
    __httpCbs[id] = opts;
    var payload = {
      id: id,
      sourceId: __currentCallSourceId,
      url: opts.url || '',
      method: (opts.method || 'GET').toUpperCase(),
      data: opts.data || null,
      header: opts.header || {},
      timeout: opts.timeout || 15000
    };
    sendMessage('http', JSON.stringify(payload));
  },
  crypto: {
    aesCbcDecrypt: function (opts) {
      opts = opts || {};
      return new Promise(function (resolve, reject) {
        var id = ++__cryptoSeq;
        __cryptoCbs[id] = { resolve: resolve, reject: reject };
        sendMessage('crypto', JSON.stringify({
          id: id,
          sourceId: __currentCallSourceId,
          operation: 'aesCbcDecrypt',
          cipherText: opts.cipherText || opts.data || '',
          key: opts.key || '',
          iv: opts.iv || '',
          inputEncoding: opts.inputEncoding || 'base64',
          keyEncoding: opts.keyEncoding || 'base64',
          ivEncoding: opts.ivEncoding || 'base64'
        }));
      });
    },
    xChaCha20Poly1305Decrypt: function (opts) {
      opts = opts || {};
      return new Promise(function (resolve, reject) {
        var id = ++__cryptoSeq;
        __cryptoCbs[id] = { resolve: resolve, reject: reject };
        sendMessage('crypto', JSON.stringify({
          id: id,
          sourceId: __currentCallSourceId,
          operation: 'xChaCha20Poly1305Decrypt',
          cipherText: opts.cipherText || opts.data || '',
          key: opts.key || '',
          nonce: opts.nonce || '',
          inputEncoding: opts.inputEncoding || 'base64',
          keyEncoding: opts.keyEncoding || 'base64',
          nonceEncoding: opts.nonceEncoding || 'base64'
        }));
      });
    }
  },
  getStorageSync: function (k) {
    var cfg = __sourceConfigs[__currentCallSourceId] || {};
    if (k === 'sourceConfig' || k === 'config') return cfg;
    if (k === 'cookie') return cfg.cookie || '';
    if (k === 'qt_cookie') return cfg.qt_cookie || cfg.cookie || '';
    if (k === 'authorization' || k === 'token') return cfg.authorization || '';
    if (k === 'userAgent') return cfg.userAgent || '';
    return __store[k];
  },
  setStorageSync: function (k, v) { __store[k] = v; }
};

// Dart 完成 HTTP 后回调(env = {statusCode, data})
function __httpResolve(id, envJson) {
  var cb = __httpCbs[id]; if (!cb) return;
  delete __httpCbs[id];
  var env;
  try { env = JSON.parse(envJson); } catch (e) { env = { statusCode: 0, data: null }; }
  if (typeof cb.success === 'function') {
    try { cb.success({ statusCode: env.statusCode, header: env.header || {}, data: env.data }); } catch (e) {}
  }
}
function __httpReject(id, errMsg) {
  var cb = __httpCbs[id]; if (!cb) return;
  delete __httpCbs[id];
  if (typeof cb.fail === 'function') {
    try { cb.fail({ errMsg: errMsg || 'request fail' }); } catch (e) {}
  }
}

function __cryptoResolve(id, envJson) {
  var cb = __cryptoCbs[id]; if (!cb) return;
  delete __cryptoCbs[id];
  var env;
  try { env = JSON.parse(envJson); } catch (e) { env = { data: '' }; }
  cb.resolve(env.data == null ? '' : env.data);
}
function __cryptoReject(id, errMsg) {
  var cb = __cryptoCbs[id]; if (!cb) return;
  delete __cryptoCbs[id];
  cb.reject(new Error(errMsg || 'crypto fail'));
}

// ── 音源注册表 ──
var __sources = {};

function __setSourceConfig(sourceId, configJson) {
  var cfg = {};
  try { cfg = JSON.parse(configJson || '{}') || {}; } catch (e) { cfg = {}; }
  __sourceConfigs[sourceId] = cfg;
  if (__sources[sourceId]) __sources[sourceId].config = cfg;
}

// 编译用户音源代码(({...}) 形式),按 id 注册,返回 {id,name}
function __loadSource(code) {
  var src = new Function('uni', 'return (\n' + code + '\n)')(uni);
  if (!src || typeof src !== 'object') throw new Error('音源必须导出对象');
  if (!src.id || typeof src.id !== 'string') throw new Error('音源缺少字符串 id');
  if (!src.name || typeof src.name !== 'string') throw new Error('音源缺少字符串 name');
  var apiVersion = Number(src.apiVersion || src.version || 1);
  if (apiVersion !== 1) throw new Error('不支持的音源协议版本: ' + apiVersion);
  ['search', 'getChapters', 'getAudioUrl'].forEach(function (method) {
    if (typeof src[method] !== 'function') throw new Error('音源缺少方法: ' + method);
  });
  var supportsDiscover = typeof src.discover === 'function';
  var configFields = Array.isArray(src.configFields) ? src.configFields : [];
  src.config = __sourceConfigs[src.id] || {};
  __sources[src.id] = src;
  var loginUrl = '';
  var loginConfigKey = '';
  if (typeof src.loginUrl === 'string') loginUrl = src.loginUrl;
  if (src.login && typeof src.login === 'object') {
    if (!loginUrl && typeof src.login.url === 'string') loginUrl = src.login.url;
    if (typeof src.login.configKey === 'string') loginConfigKey = src.login.configKey;
  }
  return JSON.stringify({
    id: src.id,
    name: src.name,
    apiVersion: apiVersion,
    configFields: configFields,
    loginUrl: loginUrl,
    loginConfigKey: loginConfigKey,
    supportsDiscover: supportsDiscover
  });
}

// 调用音源方法,结果经 result 通道异步回 Dart
function __call(reqId, sourceId, method, argsJson) {
  var src = __sources[sourceId];
  if (!src) { sendMessage('result', JSON.stringify({ reqId: reqId, ok: false, err: '音源未加载: ' + sourceId })); return; }
  if (typeof src[method] !== 'function') { sendMessage('result', JSON.stringify({ reqId: reqId, ok: false, err: '音源无方法: ' + method })); return; }
  src.config = __sourceConfigs[sourceId] || {};
  var args;
  try { args = JSON.parse(argsJson) || []; } catch (e) { args = []; }
  Promise.resolve().then(function () {
    __currentCallSourceId = sourceId;
    return src[method].apply(src, args);
  }).then(function (r) {
    sendMessage('result', JSON.stringify({ reqId: reqId, ok: true, data: r }));
  }).catch(function (e) {
    sendMessage('result', JSON.stringify({ reqId: reqId, ok: false, err: String((e && e.message) || e) }));
  }).then(function () {
    if (__currentCallSourceId === sourceId) __currentCallSourceId = '';
  });
}
