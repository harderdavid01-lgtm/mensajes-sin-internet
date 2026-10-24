package com.davy.mensajes_sin_internet

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import org.json.JSONArray
import org.json.JSONObject

// Recibe los SMS aunque la app esté cerrada. Solo guarda los que traen la marca [MSI:...]
// (los que mandó esta app). La app los lee la próxima vez que se abra o en segundos si está abierta.
class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val partes = try {
            Telephony.Sms.Intents.getMessagesFromIntent(intent)
        } catch (_: Exception) { null } ?: return
        if (partes.isEmpty()) return
        val de = partes[0].originatingAddress ?: return
        val texto = partes.joinToString("") { it.messageBody ?: "" }
        if (!texto.contains("[MSI:")) return

        synchronized(SmsReceiver::class.java) {
            val prefs = context.getSharedPreferences(ARCHIVO, Context.MODE_PRIVATE)
            val lista = try { JSONArray(prefs.getString(CLAVE, "[]")) } catch (_: Exception) { JSONArray() }
            lista.put(
                JSONObject()
                    .put("de", de)
                    .put("texto", texto)
                    .put("hora", partes[0].timestampMillis)
            )
            prefs.edit().putString(CLAVE, lista.toString()).apply()
        }
    }

    companion object {
        private const val ARCHIVO = "msi_sms"
        private const val CLAVE = "bandeja"

        /** Devuelve los SMS guardados (como texto JSON) y vacía la bandeja. */
        fun sacarBandeja(context: Context): String {
            synchronized(SmsReceiver::class.java) {
                val prefs = context.getSharedPreferences(ARCHIVO, Context.MODE_PRIVATE)
                val s = prefs.getString(CLAVE, "[]") ?: "[]"
                prefs.edit().putString(CLAVE, "[]").commit()
                return s
            }
        }
    }
}
