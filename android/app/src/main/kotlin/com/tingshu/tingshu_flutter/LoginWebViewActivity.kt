package com.tingshu.tingshu_flutter

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

class LoginWebViewActivity : Activity() {
    private lateinit var webView: WebView
    private lateinit var progressBar: ProgressBar
    private var initialUrl = ""
    private var currentUrl = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialUrl = intent.getStringExtra("url") ?: ""
        currentUrl = initialUrl
        val title = intent.getStringExtra("title") ?: "音源登录"
        val userAgent = intent.getStringExtra("userAgent") ?: ""

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }
        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(16, 10, 12, 10)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }
        val titleView = TextView(this).apply {
            text = title
            textSize = 18f
            maxLines = 1
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val doneButton = Button(this).apply {
            text = "完成"
            setOnClickListener { finishWithCookie(Activity.RESULT_OK) }
        }
        toolbar.addView(titleView)
        toolbar.addView(doneButton)
        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                6
            )
        }
        webView = WebView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
        }
        root.addView(toolbar)
        root.addView(progressBar)
        root.addView(webView)
        setContentView(root)

        val cookieManager = CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)
        cookieManager.setAcceptThirdPartyCookies(webView, true)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            if (userAgent.isNotBlank()) {
                userAgentString = userAgent
            }
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?
            ): Boolean {
                currentUrl = request?.url?.toString() ?: currentUrl
                return false
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                currentUrl = url ?: currentUrl
                CookieManager.getInstance().flush()
            }
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                progressBar.progress = newProgress
            }
        }
        if (initialUrl.isBlank()) {
            finishWithCookie(Activity.RESULT_CANCELED)
        } else {
            webView.loadUrl(initialUrl)
        }
    }

    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
            return
        }
        finishWithCookie(Activity.RESULT_OK)
    }

    override fun onDestroy() {
        if (::webView.isInitialized) {
            webView.destroy()
        }
        super.onDestroy()
    }

    private fun finishWithCookie(resultCode: Int) {
        CookieManager.getInstance().flush()
        val result = Intent().apply {
            putExtra("cookie", collectCookies())
            putExtra("url", currentUrl)
        }
        setResult(resultCode, result)
        finish()
    }

    private fun collectCookies(): String {
        val manager = CookieManager.getInstance()
        val values = linkedSetOf<String>()
        listOf(currentUrl, initialUrl).forEach { url ->
            if (url.isNotBlank()) {
                val raw = manager.getCookie(url) ?: ""
                raw.split(";")
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .forEach { values.add(it) }
            }
        }
        return values.joinToString("; ")
    }
}
