package com.tingshu.tingshu_flutter

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import java.net.URI

class AudioSnifferActivity : Activity() {
    private lateinit var webView: WebView
    private val handler = Handler(Looper.getMainLooper())
    private var pageUrl = ""
    private var clickSelector = ""
    private var waitMs = 3000
    private var finished = false
    private val patterns = mutableListOf<String>()
    private val headers = linkedMapOf<String, String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pageUrl = intent.getStringExtra("url") ?: ""
        clickSelector = intent.getStringExtra("click") ?: ""
        waitMs = intent.getIntExtra("waitMs", 3000).coerceIn(500, 20000)
        patterns.addAll(intent.getStringArrayListExtra("audioPatterns") ?: arrayListOf())
        headers.putAll(parseHeaders(intent.getStringExtra("headers") ?: ""))
        val userAgent = intent.getStringExtra("userAgent") ?: ""

        if (pageUrl.isBlank()) {
            finishError("嗅探页面地址为空")
            return
        }

        webView = WebView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }
        setContentView(FrameLayout(this).apply { addView(webView) })

        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
        seedCookies(pageUrl)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            mediaPlaybackRequiresUserGesture = false
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            val effectiveUa = userAgent.ifBlank { headerValue("User-Agent") }
            if (effectiveUa.isNotBlank()) userAgentString = effectiveUa
        }
        webView.webChromeClient = WebChromeClient()
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?
            ): Boolean {
                inspectUrl(request?.url?.toString() ?: "")
                return false
            }

            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest?
            ): android.webkit.WebResourceResponse? {
                inspectUrl(request?.url?.toString() ?: "")
                return super.shouldInterceptRequest(view, request)
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                CookieManager.getInstance().flush()
                handler.postDelayed({ triggerAndScan() }, 300)
                handler.postDelayed({ scanPageResources() }, waitMs.toLong())
            }
        }

        handler.postDelayed({
            if (!finished) finishError("嗅探超时，未发现音频资源")
        }, 20000)
        webView.loadUrl(pageUrl, headers)
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (::webView.isInitialized) webView.destroy()
        super.onDestroy()
    }

    private fun triggerAndScan() {
        if (finished) return
        if (clickSelector.isNotBlank()) {
            val js = """
                (function(){
                  var el=document.querySelector(${quote(clickSelector)});
                  if(el){ el.click(); return 'clicked'; }
                  return 'missing';
                })();
            """.trimIndent()
            webView.evaluateJavascript(js, null)
        }
        scanPageResources()
    }

    private fun scanPageResources() {
        if (finished) return
        val js = """
            (function(){
              var out=[];
              function add(v){ if(v && typeof v === 'string') out.push(v); }
              document.querySelectorAll('audio,video,source').forEach(function(el){
                add(el.currentSrc); add(el.src);
              });
              if(window.performance && performance.getEntriesByType){
                performance.getEntriesByType('resource').forEach(function(e){ add(e.name); });
              }
              return JSON.stringify(out);
            })();
        """.trimIndent()
        webView.evaluateJavascript(js, ValueCallback { value ->
            val list = parseJsStringArray(value)
            for (url in list) {
                if (inspectUrl(url)) return@ValueCallback
            }
            if (!finished) handler.postDelayed({ scanPageResources() }, 1000)
        })
    }

    private fun inspectUrl(raw: String): Boolean {
        if (finished || raw.isBlank()) return false
        val normalized = normalizeUrl(raw)
        if (!looksAudio(normalized)) return false
        finishSuccess(normalized)
        return true
    }

    private fun normalizeUrl(raw: String): String {
        if (raw.startsWith("//")) return "https:$raw"
        if (raw.startsWith("http://") || raw.startsWith("https://")) return raw
        return try {
            URI(pageUrl).resolve(raw).toString()
        } catch (_: Exception) {
            raw
        }
    }

    private fun looksAudio(url: String): Boolean {
        val lower = url.lowercase()
        if (patterns.any { it.isNotBlank() && lower.contains(it.lowercase()) }) return true
        return lower.contains(".mp3") ||
            lower.contains(".m4a") ||
            lower.contains(".m4b") ||
            lower.contains(".aac") ||
            lower.contains(".flac") ||
            lower.contains(".wav") ||
            lower.contains(".ogg") ||
            lower.contains(".opus") ||
            lower.contains(".m3u8") ||
            lower.contains("mime=audio") ||
            lower.contains("audio/")
    }

    private fun finishSuccess(url: String) {
        if (finished) return
        finished = true
        val resultHeaders = linkedMapOf<String, String>()
        headerValue("User-Agent").takeIf { it.isNotBlank() }?.let {
            resultHeaders["User-Agent"] = it
        }
        val referer = headerValue("Referer").ifBlank { pageUrl }
        if (referer.isNotBlank()) resultHeaders["Referer"] = referer
        val cookie = mergedCookies(url)
        if (cookie.isNotBlank()) resultHeaders["Cookie"] = cookie
        setResult(Activity.RESULT_OK, Intent().apply {
            putExtra("url", url)
            putExtra("headers", encodeHeaders(resultHeaders))
        })
        finish()
    }

    private fun finishError(message: String) {
        if (finished) return
        finished = true
        setResult(Activity.RESULT_CANCELED, Intent().apply {
            putExtra("error", message)
        })
        finish()
    }

    private fun parseHeaders(raw: String): Map<String, String> {
        if (raw.isBlank()) return emptyMap()
        return raw.split("\n").mapNotNull {
            val idx = it.indexOf(":")
            if (idx <= 0) null else it.substring(0, idx) to it.substring(idx + 1)
        }.associate { it.first.trim() to it.second.trim() }
    }

    private fun encodeHeaders(map: Map<String, String>): String {
        return map.entries.joinToString("\n") { "${it.key}:${it.value}" }
    }

    private fun headerValue(name: String): String {
        return headers.entries.firstOrNull {
            it.key.equals(name, ignoreCase = true)
        }?.value ?: ""
    }

    private fun seedCookies(url: String) {
        val cookie = headerValue("Cookie")
        if (cookie.isBlank()) return
        val manager = CookieManager.getInstance()
        cookie.split(";")
            .map { it.trim() }
            .filter { it.isNotBlank() }
            .forEach { manager.setCookie(url, it) }
        manager.flush()
    }

    private fun mergedCookies(audioUrl: String): String {
        val manager = CookieManager.getInstance()
        val values = linkedSetOf<String>()
        headerValue("Cookie").split(";")
            .map { it.trim() }
            .filter { it.isNotBlank() }
            .forEach { values.add(it) }
        listOf(audioUrl, pageUrl).forEach { url ->
            val raw = manager.getCookie(url) ?: ""
            raw.split(";")
                .map { it.trim() }
                .filter { it.isNotBlank() }
                .forEach { values.add(it) }
        }
        return values.joinToString("; ")
    }

    private fun parseJsStringArray(raw: String?): List<String> {
        val value = raw ?: return emptyList()
        val trimmed = value.trim().trim('"')
            .replace("\\\"", "\"")
            .replace("\\/", "/")
        val regex = Regex("\"([^\"]+)\"")
        return regex.findAll(trimmed).map { it.groupValues[1] }.toList()
    }

    private fun quote(value: String): String {
        return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
    }
}
