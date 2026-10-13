package com.k1ngmew.liangrenzhang

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.ByteArrayInputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLEncoder
import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.cert.Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * Keeps one PocketBase realtime (SSE) connection subscribed to the user's
 * `alerts` collection and turns new unread alerts into system notifications,
 * so budget reminders arrive while the app is in the background.
 */
class AlertService : Service() {
    @Volatile private var running = false
    private var worker: Thread? = null
    @Volatile private var connection: HttpURLConnection? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = Notification.Builder(this, CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentTitle("两人账")
            .setContentText("正在守护你们的小金库")
            .setContentIntent(openAppIntent(this))
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(ID_SERVICE, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID_SERVICE, notification)
        }

        // restart the loop so a refreshed token / server address is picked up
        stopWorker()
        running = true
        worker = Thread(::loop, "alert-sse").also { it.start() }
        return START_STICKY
    }

    override fun onDestroy() {
        stopWorker()
        super.onDestroy()
    }

    private fun stopWorker() {
        running = false
        connection?.disconnect()
        worker?.interrupt()
        worker = null
    }

    private fun loop() {
        var backoff = 5_000L
        while (running) {
            val cfg = Config.load(prefs(this))
            if (cfg == null) {
                stopSelf()
                return
            }
            try {
                listen(cfg)
                backoff = 5_000L
            } catch (e: AuthException) {
                notifyText(this, ID_AUTH, "登录已过期", "打开两人账重新登录，才能继续收到超支提醒")
                disable(this)
                return
            } catch (e: InterruptedException) {
                return
            } catch (e: Exception) {
                Log.w(TAG, "realtime connection failed: ${e.message}")
            }
            if (!running) return
            try {
                Thread.sleep(backoff)
            } catch (e: InterruptedException) {
                return
            }
            backoff = (backoff * 2).coerceAtMost(60_000L)
        }
    }

    /** One SSE session; returns when the server closes the stream. */
    private fun listen(cfg: Config) {
        val conn = open(cfg, "/api/realtime")
        conn.setRequestProperty("Accept", "text/event-stream")
        // PocketBase drops idle clients after ~5 min; this also catches half-open sockets
        conn.readTimeout = 6 * 60 * 1000
        connection = conn
        try {
            if (conn.responseCode != 200) throw IllegalStateException("realtime HTTP ${conn.responseCode}")
            val reader = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8))
            var event = ""
            val data = StringBuilder()
            while (running) {
                val line = try {
                    reader.readLine()
                } catch (e: SocketTimeoutException) {
                    return
                } ?: return
                when {
                    line.isEmpty() -> {
                        if (data.isNotEmpty()) handleEvent(cfg, event, data.toString())
                        event = ""
                        data.setLength(0)
                    }
                    line.startsWith("event:") -> event = line.substring(6).trim()
                    line.startsWith("data:") -> data.append(line.substring(5).trim())
                }
            }
        } finally {
            conn.disconnect()
            connection = null
        }
    }

    private fun handleEvent(cfg: Config, event: String, data: String) {
        val json = JSONObject(data)
        when (event) {
            "PB_CONNECT" -> {
                subscribe(cfg, json.getString("clientId"))
                catchUp(cfg)
            }
            "alerts" -> {
                val record = json.optJSONObject("record") ?: return
                if (json.optString("action") == "create" && !record.optBoolean("read")) {
                    show(record)
                }
            }
        }
    }

    private fun subscribe(cfg: Config, clientId: String) {
        val conn = open(cfg, "/api/realtime")
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("Authorization", cfg.token)
            val body = JSONObject().put("clientId", clientId).put("subscriptions", org.json.JSONArray().put("alerts"))
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            when (conn.responseCode) {
                in 200..299 -> Unit
                401, 403 -> throw AuthException()
                else -> throw IllegalStateException("subscribe HTTP ${conn.responseCode}")
            }
        } finally {
            conn.disconnect()
        }
    }

    /** Shows unread alerts created while we were disconnected. */
    private fun catchUp(cfg: Config) {
        val filter = URLEncoder.encode("read = false", "UTF-8")
        val conn = open(cfg, "/api/collections/alerts/records?perPage=20&sort=-created&filter=$filter")
        try {
            conn.setRequestProperty("Authorization", cfg.token)
            when (conn.responseCode) {
                200 -> Unit
                401, 403 -> throw AuthException()
                else -> return
            }
            val text = conn.inputStream.bufferedReader().use { it.readText() }
            val items = JSONObject(text).optJSONArray("items") ?: return
            for (i in items.length() - 1 downTo 0) show(items.getJSONObject(i))
        } finally {
            conn.disconnect()
        }
    }

    private fun show(record: JSONObject) {
        val id = record.optString("id")
        val p = prefs(this)
        val shown = p.getStringSet(KEY_SHOWN, emptySet())!!.toMutableSet()
        if (id.isEmpty() || shown.contains(id)) return
        shown.add(id)
        // keep the set small; old ids can never come back as unread
        val trimmed = if (shown.size > 200) shown.toList().takeLast(100).toSet() else shown
        p.edit().putStringSet(KEY_SHOWN, trimmed).apply()

        // the open app already shows the alert as a dialog
        if (appInForeground()) return
        notifyText(this, id.hashCode(), record.optString("title", "友情提醒"), record.optString("body"))
    }

    private fun appInForeground(): Boolean {
        val info = android.app.ActivityManager.RunningAppProcessInfo()
        android.app.ActivityManager.getMyMemoryState(info)
        return info.importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    private fun open(cfg: Config, path: String): HttpURLConnection {
        val conn = URL(cfg.baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 20_000
        if (conn is HttpsURLConnection) {
            cfg.trust?.let {
                conn.sslSocketFactory = it.socketFactory
                conn.hostnameVerifier = it.hostnameVerifier
            }
        }
        return conn
    }

    private class AuthException : Exception()

    private class Trust(val socketFactory: SSLSocketFactory, val hostnameVerifier: HostnameVerifier)

    private class Config(val baseUrl: String, val token: String, val trust: Trust?) {
        companion object {
            fun load(p: SharedPreferences): Config? {
                if (!p.getBoolean(KEY_ENABLED, false)) return null
                val base = p.getString(KEY_BASE_URL, "") ?: ""
                val token = p.getString(KEY_TOKEN, "") ?: ""
                if (base.isEmpty() || token.isEmpty()) return null
                return Config(base, token, trustFor(p.getString(KEY_CA, "") ?: ""))
            }
        }
    }

    companion object {
        private const val TAG = "AlertService"
        private const val PREFS = "alert_service"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_BASE_URL = "base_url"
        private const val KEY_TOKEN = "token"
        private const val KEY_USER = "user_id"
        private const val KEY_CA = "ca_pem"
        private const val KEY_SHOWN = "shown_ids"

        private const val CHANNEL_SERVICE = "background"
        private const val CHANNEL_ALERTS = "alerts"
        private const val ID_SERVICE = 1
        private const val ID_AUTH = 2
        private val PEM_BLOCK = Regex("-----BEGIN CERTIFICATE-----[\\s\\S]+?-----END CERTIFICATE-----")

        fun prefs(ctx: Context): SharedPreferences = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun configure(ctx: Context, baseUrl: String, token: String, userId: String, caPem: String) {
            val p = prefs(ctx)
            val edit = p.edit()
            if (p.getString(KEY_USER, "") != userId) edit.remove(KEY_SHOWN)
            edit.putBoolean(KEY_ENABLED, true)
                .putString(KEY_BASE_URL, baseUrl)
                .putString(KEY_TOKEN, token)
                .putString(KEY_USER, userId)
                .putString(KEY_CA, caPem)
                .apply()
        }

        fun isEnabled(ctx: Context) = prefs(ctx).getBoolean(KEY_ENABLED, false)

        fun start(ctx: Context) {
            if (!isEnabled(ctx)) return
            ctx.startForegroundService(Intent(ctx, AlertService::class.java))
        }

        fun disable(ctx: Context) {
            prefs(ctx).edit().putBoolean(KEY_ENABLED, false).remove(KEY_TOKEN).apply()
            ctx.stopService(Intent(ctx, AlertService::class.java))
        }

        fun ensureChannels(ctx: Context) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_SERVICE, "后台连接", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "保持和服务器的连接，用来接收超支提醒"
                    setShowBadge(false)
                }
            )
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ALERTS, "超支提醒", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "本月预算用到 80%、用完、超支时的友情提醒"
                }
            )
        }

        fun openAppIntent(ctx: Context): PendingIntent = PendingIntent.getActivity(
            ctx,
            0,
            Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        fun notifyText(ctx: Context, id: Int, title: String, body: String) {
            ensureChannels(ctx)
            val n = Notification.Builder(ctx, CHANNEL_ALERTS)
                .setSmallIcon(R.drawable.ic_stat_notify)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setContentIntent(openAppIntent(ctx))
                .setAutoCancel(true)
                .build()
            ctx.getSystemService(NotificationManager::class.java).notify(id, n)
        }

        /**
         * Trusts, besides the system CAs, the certificates the app passes in
         * [pem]: our own root CA and server certificates the user confirmed
         * by fingerprint. A confirmed server certificate is accepted as is,
         * like the app does, even though nothing vouches for it.
         */
        private fun trustFor(pem: String): Trust? {
            if (pem.isBlank()) return null
            return try {
                // one at a time: Android may only read the first of several concatenated PEMs
                val factory = CertificateFactory.getInstance("X.509")
                val certs = PEM_BLOCK.findAll(pem)
                    .map { factory.generateCertificate(ByteArrayInputStream(it.value.toByteArray())) as X509Certificate }
                    .toList()
                if (certs.isEmpty()) return null
                val ks = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
                    load(null, null)
                    certs.forEachIndexed { i, cert -> setCertificateEntry("trusted-$i", cert) }
                }
                val custom = trustManager(ks)
                val system = trustManager(null)
                fun confirmed(chain: Array<out Certificate>?): Boolean {
                    val leaf = chain?.firstOrNull() ?: return false
                    return certs.any { it.encoded.contentEquals(leaf.encoded) }
                }
                val combined = object : X509TrustManager {
                    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
                        system.checkClientTrusted(chain, authType)

                    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                        if (confirmed(chain)) return
                        try {
                            custom.checkServerTrusted(chain, authType)
                        } catch (e: CertificateException) {
                            system.checkServerTrusted(chain, authType)
                        }
                    }

                    override fun getAcceptedIssuers(): Array<X509Certificate> =
                        custom.acceptedIssuers + system.acceptedIssuers
                }
                val defaultVerifier = HttpsURLConnection.getDefaultHostnameVerifier()
                val verifier = HostnameVerifier { host, session ->
                    defaultVerifier.verify(host, session) || try {
                        confirmed(session.peerCertificates)
                    } catch (e: SSLPeerUnverifiedException) {
                        false
                    }
                }
                val socketFactory = SSLContext.getInstance("TLS").apply { init(null, arrayOf(combined), null) }.socketFactory
                Trust(socketFactory, verifier)
            } catch (e: Exception) {
                Log.e(TAG, "invalid trusted certificates", e)
                null
            }
        }

        private fun trustManager(ks: KeyStore?): X509TrustManager {
            val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            tmf.init(ks)
            return tmf.trustManagers.filterIsInstance<X509TrustManager>().first()
        }
    }
}
