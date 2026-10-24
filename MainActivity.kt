package com.davy.mensajes_sin_internet

import android.app.Activity
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Código nativo de Android: enviar SMS, leer los SMS que llegaron
// y revisar si Bluetooth / Wi-Fi / GPS / SIM están encendidos.
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "msi/nativo")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enviarSms" -> {
                        val tel = call.argument<String>("tel")
                        val texto = call.argument<String>("texto")
                        if (tel == null || texto == null) result.success(false)
                        else enviarSms(tel, texto, result)
                    }
                    "leerSms" -> result.success(SmsReceiver.sacarBandeja(this))
                    "radios" -> result.success(radios())
                    else -> result.notImplemented()
                }
            }
    }

    private fun enviarSms(tel: String, texto: String, result: MethodChannel.Result) {
        try {
            val sms: SmsManager = if (Build.VERSION.SDK_INT >= 31) {
                getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
            val partes = sms.divideMessage(texto)
            val accion = "msi.SMS_ENVIADO." + System.nanoTime()
            var pendientes = partes.size
            var todoBien = true
            var respondido = false
            val handler = Handler(Looper.getMainLooper())

            val receptor = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    if (resultCode != Activity.RESULT_OK) todoBien = false
                    pendientes--
                    if (pendientes <= 0 && !respondido) {
                        respondido = true
                        try { unregisterReceiver(this) } catch (_: Exception) {}
                        result.success(todoBien)
                    }
                }
            }
            val filtro = IntentFilter(accion)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receptor, filtro, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(receptor, filtro)
            }

            val avisos = ArrayList<PendingIntent>()
            for (k in partes.indices) {
                val intent = Intent(accion).setPackage(packageName)
                avisos.add(
                    PendingIntent.getBroadcast(
                        this, k, intent,
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT
                    )
                )
            }
            sms.sendMultipartTextMessage(tel, null, partes, avisos, null)

            // Si en 60 segundos no hubo respuesta, lo damos por fallido
            handler.postDelayed({
                if (!respondido) {
                    respondido = true
                    try { unregisterReceiver(receptor) } catch (_: Exception) {}
                    result.success(false)
                }
            }, 60000)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun radios(): Map<String, Boolean> {
        val r = HashMap<String, Boolean>()
        r["bluetooth"] = try {
            (getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter?.isEnabled == true
        } catch (_: Exception) { false }
        r["wifi"] = try {
            (applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)?.isWifiEnabled == true
        } catch (_: Exception) { false }
        r["ubicacion"] = try {
            val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled
            else lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } catch (_: Exception) { false }
        r["sim"] = try {
            (getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager).simState ==
                TelephonyManager.SIM_STATE_READY
        } catch (_: Exception) { false }
        r["internet"] = try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        } catch (_: Exception) { false }
        return r
    }
}
