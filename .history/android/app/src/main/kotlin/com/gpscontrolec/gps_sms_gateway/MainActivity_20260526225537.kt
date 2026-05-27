package com.gpscontrolec.gps_sms_gateway

import android.app.PendingIntent
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.Telephony
import android.telephony.SmsManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val inboxChannel = "gps_gateway/sms_inbox"
    private val sendChannel  = "gps_gateway/sms_send"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Canal: leer bandeja ──────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, inboxChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readInbox" -> {
                        val limit = call.argument<Int>("limit") ?: 30
                        try {
                            result.success(readInboxSms(limit))
                        } catch (e: Exception) {
                            result.error("INBOX_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Canal: enviar SMS ────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, sendChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendSms" -> {
                        val to   = call.argument<String>("to")   ?: ""
                        val body = call.argument<String>("body") ?: ""
                        try {
                            sendSmsNative(to, body)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SMS_SEND_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── Leer bandeja SMS ─────────────────────────────────────────────────
    private fun readInboxSms(limit: Int): List<Map<String, Any?>> {
        val smsList = mutableListOf<Map<String, Any?>>()

        val cursor: Cursor? = contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE),
            null, null,
            "${Telephony.Sms.DATE} DESC"
        )

        cursor?.use {
            val idIdx      = it.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addressIdx = it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIdx    = it.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIdx    = it.getColumnIndexOrThrow(Telephony.Sms.DATE)

            var count = 0
            while (it.moveToNext() && count < limit) {
                smsList.add(mapOf(
                    "id"   to it.getLong(idIdx).toString(),
                    "from" to (it.getString(addressIdx) ?: ""),
                    "body" to (it.getString(bodyIdx) ?: ""),
                    "date" to it.getLong(dateIdx).toString()
                ))
                count++
            }
        }

        return smsList
    }

    // ── Enviar SMS nativo (sin telephony plugin) ─────────────────────────
    @Suppress("DEPRECATION")
    private fun sendSmsNative(to: String, body: String) {
        val smsManager: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            applicationContext.getSystemService(SmsManager::class.java)
        } else {
            SmsManager.getDefault()
        }

        val parts = smsManager.divideMessage(body)

        if (parts.size == 1) {
            smsManager.sendTextMessage(to, null, body, null, null)
        } else {
            smsManager.sendMultipartTextMessage(to, null, parts, null, null)
        }
    }
}