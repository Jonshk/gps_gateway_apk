package com.gpscontrolec.gps_sms_gateway

import android.database.Cursor
import android.net.Uri
import android.provider.Telephony
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "gps_gateway/sms_inbox"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "readInbox" -> {
                    val limit = call.argument<Int>("limit") ?: 30
                    result.success(readInboxSms(limit))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun readInboxSms(limit: Int): List<Map<String, Any?>> {
        val smsList = mutableListOf<Map<String, Any?>>()

        val uri: Uri = Telephony.Sms.Inbox.CONTENT_URI

        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE
        )

        val cursor: Cursor? = contentResolver.query(
            uri,
            projection,
            null,
            null,
            "${Telephony.Sms.DATE} DESC"
        )

        cursor?.use {
            val idIndex = it.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addressIndex = it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIndex = it.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIndex = it.getColumnIndexOrThrow(Telephony.Sms.DATE)

            var count = 0

            while (it.moveToNext() && count < limit) {
                val id = it.getLong(idIndex).toString()
                val from = it.getString(addressIndex) ?: ""
                val body = it.getString(bodyIndex) ?: ""
                val date = it.getLong(dateIndex).toString()

                smsList.add(
                    mapOf(
                        "id" to id,
                        "from" to from,
                        "body" to body,
                        "date" to date
                    )
                )

                count++
            }
        }

        return smsList
    }
}