package com.gpscontrolec.gps_sms_gateway

import android.app.*
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class GatewayService : Service() {

    companion object {
        const val TAG = "GatewayService"
        const val CHANNEL_ID = "gps_gateway"
        const val NOTIF_ID = 888

        fun getApiBase(ctx: Context): String =
            ctx.getSharedPreferences("gateway_config", MODE_PRIVATE)
                .getString("api_base", "") ?: ""

        fun getApiKey(ctx: Context): String =
            ctx.getSharedPreferences("gateway_config", MODE_PRIVATE)
                .getString("api_key", "") ?: ""

        fun getPollSecs(ctx: Context): Long =
            ctx.getSharedPreferences("gateway_config", MODE_PRIVATE)
                .getLong("poll_secs", 15L)
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val processedSmsIds = mutableSetOf<String>()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification("GPS Gateway activo"))
        Log.d(TAG, "GatewayService iniciado")
        startLoops()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() { super.onDestroy(); scope.cancel() }

    private fun startLoops() {
        val pollSecs = getPollSecs(this)

        scope.launch {
            while (isActive) {
                try { processPendingCommands() } catch (e: Exception) {
                    Log.e(TAG, "processPendingCommands error: ${e.message}")
                }
                delay(pollSecs * 1000)
            }
        }

        scope.launch {
            while (isActive) {
                try { readInboxAndUpload() } catch (e: Exception) {
                    Log.e(TAG, "readInboxAndUpload error: ${e.message}")
                }
                delay(10_000)
            }
        }
    }

    private suspend fun processPendingCommands() {
        val apiBase = getApiBase(this)
        val apiKey  = getApiKey(this)
        if (apiBase.isEmpty()) return

        val commands = fetchPendingCommands(apiBase, apiKey) ?: return

        for (i in 0 until commands.length()) {
            val cmd      = commands.getJSONObject(i)
            val id       = cmd.getString("id")
            val to       = cmd.getString("to")
            val body     = cmd.getString("body")
            val command  = cmd.optString("command", "")
            val needsCall = command == "monitor" || body.lowercase().startsWith("monitor")

            Log.d(TAG, "sending SMS to $to: $body (needsCall=$needsCall)")
            val sent = sendSms(to, body)
            Log.d(TAG, "SMS sent=$sent to $to")

            if (sent && needsCall) {
                Log.d(TAG, "waiting 3s before calling $to")
                delay(3_000)
                makeCall(to)
            }

            confirmCommand(apiBase, apiKey, id, sent)
        }
    }

    // ── Llamada directa al GPS ────────────────────────────────────────
    private fun makeCall(to: String) {
        try {
            val intent = Intent(Intent.ACTION_CALL).apply {
                data = Uri.parse("tel:$to")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            Log.d(TAG, "calling $to")
        } catch (e: Exception) {
            Log.e(TAG, "makeCall error: ${e.message}")
        }
    }

    private suspend fun readInboxAndUpload() {
        val apiBase = getApiBase(this)
        val apiKey  = getApiKey(this)
        if (apiBase.isEmpty()) return

        val cursor = contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE),
            null, null,
            "${Telephony.Sms.DATE} DESC LIMIT 30"
        ) ?: return

        cursor.use {
            val idIdx      = it.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addressIdx = it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIdx    = it.getColumnIndexOrThrow(Telephony.Sms.BODY)

            while (it.moveToNext()) {
                val id   = it.getLong(idIdx).toString()
                val from = it.getString(addressIdx) ?: ""
                val body = it.getString(bodyIdx) ?: ""

                if (id.isEmpty() || body.isEmpty()) continue
                if (processedSmsIds.contains(id)) continue

                processedSmsIds.add(id)
                Log.d(TAG, "inbox SMS id=$id from=$from")
                reportIncomingSms(apiBase, apiKey, from, body)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun sendSms(to: String, body: String): Boolean {
        return try {
            val smsManager: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(SmsManager::class.java)
            } else {
                SmsManager.getDefault()
            }
            val parts = smsManager.divideMessage(body)
            if (parts.size == 1) {
                smsManager.sendTextMessage(to, null, body, null, null)
            } else {
                smsManager.sendMultipartTextMessage(to, null, parts, null, null)
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "sendSms error: ${e.message}")
            false
        }
    }

    private fun fetchPendingCommands(apiBase: String, apiKey: String): JSONArray? {
        return try {
            val url = URL("$apiBase/gateway/pending")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("x-api-key", apiKey)
                connectTimeout = 10_000
                readTimeout = 10_000
            }
            if (conn.responseCode == 200) JSONArray(conn.inputStream.bufferedReader().readText())
            else null
        } catch (e: Exception) {
            Log.e(TAG, "fetchPending error: ${e.message}")
            null
        }
    }

    private fun confirmCommand(apiBase: String, apiKey: String, commandId: String, success: Boolean) {
        try {
            val body = JSONObject().apply {
                put("command_id", commandId)
                put("success", success)
            }.toString().toByteArray()

            val conn = (URL("$apiBase/gateway/confirm").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("x-api-key", apiKey)
                doOutput = true
                connectTimeout = 10_000
                readTimeout = 10_000
            }
            conn.outputStream.write(body)
            conn.responseCode
        } catch (e: Exception) {
            Log.e(TAG, "confirmCommand error: ${e.message}")
        }
    }

    fun reportIncomingSms(apiBase: String, apiKey: String, from: String, body: String) {
        try {
            val payload = JSONObject().apply {
                put("from_number", from)
                put("body", body)
            }.toString().toByteArray()

            val conn = (URL("$apiBase/gateway/incoming").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("x-api-key", apiKey)
                doOutput = true
                connectTimeout = 10_000
                readTimeout = 10_000
            }
            conn.outputStream.write(payload)
            val code = conn.responseCode
            Log.d(TAG, "reported incoming from $from status=$code")
        } catch (e: Exception) {
            Log.e(TAG, "reportIncoming error: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "GPS Gateway", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val pi = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("GPS Gateway")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }
}