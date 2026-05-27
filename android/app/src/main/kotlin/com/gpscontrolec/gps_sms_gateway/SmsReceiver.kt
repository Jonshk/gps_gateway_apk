package com.gpscontrolec.gps_sms_gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (
            intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION &&
            intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION
        ) {
            return
        }

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isNullOrEmpty()) return

        val from = messages.firstOrNull()?.originatingAddress ?: ""
        val body = messages.joinToString(separator = "") { it.messageBody ?: "" }

        Log.i("GpsGatewaySms", "SMS recibido de $from: $body")

        CoroutineScope(Dispatchers.IO).launch {
            sendToBackend(from, body)
        }
    }

    private fun sendToBackend(from: String, body: String) {
        try {
            val apiBase = "https://gps-backend-ec.onrender.com"
            val apiKey = "changeme123"
            val url = URL("$apiBase/gateway/incoming")
            val conn = url.openConnection() as HttpURLConnection

            conn.requestMethod = "POST"
            conn.connectTimeout = 10000
            conn.readTimeout = 10000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("x-api-key", apiKey)

            val safeFrom = from
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")

            val safeBody = body
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")

            val payload = """{"from_number": "$safeFrom", "body": "$safeBody"}"""

            OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use {
                it.write(payload)
                it.flush()
            }

            val code = conn.responseCode
            Log.i("GpsGatewaySms", "Backend response: $code")

            conn.disconnect()
        } catch (e: Exception) {
            Log.e("GpsGatewaySms", "Error enviando SMS al backend", e)
        }
    }
}