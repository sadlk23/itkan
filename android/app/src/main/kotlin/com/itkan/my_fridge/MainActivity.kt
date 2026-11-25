package com.itkan.my_fridge

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    private var imagePickerResult: String? = null

    // image_picker_android reports gallery/camera selections on these activity
    // request codes. It copies files asynchronously after this callback and
    // does not write a lost-data entry for a cancelled activity.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 2342 || requestCode == 2343) {
            imagePickerResult = if (resultCode == Activity.RESULT_OK) "selected" else "cancelled"
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "eatkan/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "beginImagePick" -> { imagePickerResult = null; result.success(null) }
                "imagePickerResult" -> result.success(imagePickerResult)
                "notificationPermission" -> result.success(Reminders.allowed(this))
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT < 33 ||
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                    ) result.success(Reminders.allowed(this))
                    else if (permissionResult != null) result.error("busy", "Permission request active", null)
                    else { permissionResult = result; requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4321) }
                }
                "scheduleNotifications" -> {
                    try { Reminders.replace(this, JSONArray(call.arguments as? List<*> ?: emptyList<Any>())); result.success(null) }
                    catch (e: Exception) { result.error("schedule", "알림을 예약하지 못했어요", null) }
                }
                "showTestNotification" -> result.success(Reminders.show(this, 4999, "잇칸 알림 확인", "소비기한이 가까운 재료를 이곳에서 알려드려요."))
                "clearPostedNotifications" -> {
                    val mode = call.arguments as? String
                    if (mode == "demo" || mode == "personal") {
                        Reminders.clearPosted(this, mode)
                        result.success(null)
                    } else result.error("mode", "보관함 모드를 확인해주세요.", null)
                }
                "openAppSettings" -> { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))); result.success(null) }
                "openCoupangSearch" -> result.success(openCoupangSearch(call.arguments as? String))
                else -> result.notImplemented()
            }
        }
    }

    private fun openCoupangSearch(ingredient: String?): Boolean {
        if (ingredient.isNullOrBlank()) return false
        val uri = Uri.Builder()
            .scheme("https")
            .authority("www.coupang.com")
            .path("/np/search")
            .appendQueryParameter("q", ingredient)
            .build()
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage("com.coupang.mobile"))
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4321) { permissionResult?.success(Reminders.allowed(this)); permissionResult = null }
    }
}

object Reminders {
    private const val channel = "expiry"
    fun allowed(c: Context): Boolean {
        val manager = c.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 33 &&
            c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return false
        if (!manager.areNotificationsEnabled()) return false
        return Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel(channel)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    // Already scheduled and posted notifications from earlier builds only carry a title.
    fun legacyMode(title: CharSequence?): String =
        if (title?.startsWith("[샘플] ") == true) "demo" else "personal"

    fun clearPosted(c: Context, mode: String) {
        val manager = c.getSystemService(NotificationManager::class.java)
        for (posted in manager.activeNotifications) {
            if (posted.id < 100000) continue
            val owner = posted.tag ?: legacyMode(posted.notification.extras.getCharSequence(Notification.EXTRA_TITLE))
            if (owner == mode) manager.cancel(posted.tag, posted.id)
        }
    }

    fun replace(c: Context, rows: JSONArray) {
        val prefs = c.getSharedPreferences("reminders", Context.MODE_PRIVATE)
        val alarms = c.getSystemService(AlarmManager::class.java)
        val old = JSONArray(prefs.getString("schedule", "[]"))
        for (i in 0 until old.length()) {
            val existing = PendingIntent.getBroadcast(
                c, old.getJSONObject(i).getInt("id"), Intent(c, ExpiryReceiver::class.java),
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
            )
            if (existing != null) {
                alarms.cancel(existing)
                existing.cancel()
            }
        }
        prefs.edit().putString("schedule", rows.toString()).apply()
        restore(c)
    }
    fun restore(c: Context) {
        val rows = JSONArray(c.getSharedPreferences("reminders", Context.MODE_PRIVATE).getString("schedule", "[]"))
        val alarms = c.getSystemService(AlarmManager::class.java)
        // Persist all finite dates, but keep only one native alarm outstanding.
        // Delivery and reboot both advance this queue without requiring Flutter.
        var next: org.json.JSONObject? = null
        val now = System.currentTimeMillis()
        for (i in 0 until rows.length()) {
            val row = rows.getJSONObject(i); val at = row.getLong("at")
            if (at > now && (next == null || at < next.getLong("at"))) next = row
        }
        next?.let { row ->
            val id = row.getInt("id")
            val title = row.getString("title")
            val intent = Intent(c, ExpiryReceiver::class.java)
                .putExtra("id", id)
                .putExtra("title", title)
                .putExtra("body", row.getString("body"))
                .putExtra("mode", row.optString("mode", legacyMode(title)))
            val alarm = PendingIntent.getBroadcast(c, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, row.getLong("at"), alarm)
        }
    }
    fun show(c: Context, id: Int, title: String, body: String, mode: String? = null): Boolean {
        if (!allowed(c)) return false
        val manager = c.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(channel, "소비기한 알림", NotificationManager.IMPORTANCE_DEFAULT))
        val launch = PendingIntent.getActivity(c, 0, Intent(c, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(c, channel) else Notification.Builder(c)
        manager.notify(mode, id, builder.setSmallIcon(android.R.drawable.ic_menu_my_calendar).setContentTitle(title).setContentText(body).setStyle(Notification.BigTextStyle().bigText(body)).setContentIntent(launch).setAutoCancel(true).build())
        return true
    }
}
class ExpiryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Reminders.restore(context)
        val title = intent.getStringExtra("title") ?: "잇칸"
        val mode = intent.getStringExtra("mode") ?: Reminders.legacyMode(title)
        Reminders.show(context, intent.getIntExtra("id", 4000), title, intent.getStringExtra("body") ?: "", mode)
    }
}
class ReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { if (intent.action == Intent.ACTION_BOOT_COMPLETED) Reminders.restore(context) }
}
