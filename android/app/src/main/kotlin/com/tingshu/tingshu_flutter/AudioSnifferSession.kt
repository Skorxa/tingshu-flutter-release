package com.tingshu.tingshu_flutter

import android.app.Activity
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean

/** Runs a WebView behind the Flutter view so sniffing never opens a visible page. */
class AudioSnifferSession(
    private val activity: Activity,
    private val parent: ViewGroup,
    private val pageUrl: String,
    rawHeaders: String,
    private val clickSelector: String,
    waitMs: Int,
    audioPatterns: List<String>,
    private val userAgent: String,
    private val onSuccess: (url: String, headers: String) -> Unit,
    private val onError: (message: String) -> Unit
) {
    private val handler = Handler(Looper.getMainLooper())
    private val finished = AtomicBoolean(false)
    private val waitMs = waitMs.coerceIn(500, 20000)
    private val patterns = audioPatterns.filter { it.isNotBlank() }
    private val headers = parseHeaders(rawHeaders)
    private var webView: WebView? = null

    fun start() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { start() }
            return
        }
        if (pageUrl.isBlank()) {
            finishError("嗅探页面地址为空")
            return
        }
        try {
            val view = WebView(activity).apply {
                layoutParams = FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
                alpha = 0f
                setBackgroundColor(Color.TRANSPARENT)
                visibility = View.VISIBLE
                isClickable = false
                isFocusable = false
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            }
            webView = view
            // Index 0 keeps the headless WebView behind Flutter and out of the touch path.
            parent.addView(view, 0)

            CookieManager.getInstance().setAcceptCookie(true)
            CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
            seedCookies(pageUrl)
            view.settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                databaseEnabled = true
                mediaPlaybackRequiresUserGesture = false
                mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                useWideViewPort = true
                loadWithOverviewMode = true
                val effectiveUa = userAgent.ifBlank { headerValue("User-Agent") }
                if (effectiveUa.isNotBlank()) userAgentString = effectiveUa
            }
            view.webChromeClient = WebChromeClient()
            view.webViewClient = object : WebViewClient() {
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
                    handler.postDelayed({ scanPageResources() }, this@AudioSnifferSession.waitMs.toLong())
                }

                override fun onRenderProcessGone(
                    view: WebView?,
                    detail: RenderProcessGoneDetail?
                ): Boolean {
                    finishError("嗅探 WebView 进程异常退出")
                    return true
                }
            }

            handler.postDelayed({
                if (!finished.get()) finishError("嗅探超时，未发现音频资源")
            }, 20000)
            view.loadUrl(pageUrl, headers)
        } catch (error: Exception) {
            finishError(error.message ?: "无法创建后台嗅探 WebView")
        }
    }

    fun cancel() {
        if (!finished.compareAndSet(false, true)) return
        handler.post { disposeWebView() }
    }

    private fun triggerAndScan() {
        if (finished.get()) return
        val view = webView ?: return
        if (clickSelector.isNotBlank()) {
            val js = """
                (function(){
                  var el=document.querySelector(${quote(clickSelector)});
                  if(el){ el.click(); return 'clicked'; }
                  return 'missing';
                })();
            """.trimIndent()
            view.evaluateJavascript(js, null)
        }
        scanPageResources()
    }

    private fun scanPageResources() {
        if (finished.get()) return
        val view = webView ?: return
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
        view.evaluateJavascript(js, ValueCallback { value ->
            for (url in parseJsStringArray(value)) {
                if (inspectUrl(url)) return@ValueCallback
            }
            if (!finished.get()) handler.postDelayed({ scanPageResources() }, 1000)
        })
    }

    private fun inspectUrl(raw: String): Boolean {
        if (finished.get() || raw.isBlank()) return false
        val normalized = normalizeUrl(raw)
        if (!looksAudio(normalized)) return false
        if (!finished.compareAndSet(false, true)) return false
        handler.post { completeSuccess(normalized) }
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
        if (patterns.any { lower.contains(it.lowercase()) }) return true
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

    private fun completeSuccess(url: String) {
        val resultHeaders = linkedMapOf<String, String>()
        headerValue("User-Agent").takeIf { it.isNotBlank() }?.let {
            resultHeaders["User-Agent"] = it
        }
        val referer = headerValue("Referer").ifBlank { pageUrl }
        if (referer.isNotBlank()) resultHeaders["Referer"] = referer
        val cookie = mergedCookies(url)
        if (cookie.isNotBlank()) resultHeaders["Cookie"] = cookie
        disposeWebView()
        onSuccess(url, encodeHeaders(resultHeaders))
    }

    private fun finishError(message: String) {
        if (!finished.compareAndSet(false, true)) return
        handler.post {
            disposeWebView()
            onError(message)
        }
    }

    private fun disposeWebView() {
        handler.removeCallbacksAndMessages(null)
        val view = webView ?: return
        webView = null
        try {
            parent.removeView(view)
            view.stopLoading()
            view.webChromeClient = null
            view.webViewClient = WebViewClient()
            view.removeAllViews()
            view.destroy()
        } catch (_: Exception) {
            // The Activity may already be tearing down.
        }
    }

    private fun parseHeaders(raw: String): Map<String, String> {
        if (raw.isBlank()) return emptyMap()
        return raw.split("\n").mapNotNull {
            val index = it.indexOf(":")
            if (index <= 0) null else it.substring(0, index) to it.substring(index + 1)
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
