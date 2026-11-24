package com.example.vivora.reminders

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.example.vivora.R
import org.json.JSONObject
import java.util.Calendar

/**
 * Local reminders without any notification service or extra plugin.
 *
 * Daily reminders use inexact, Doze-friendly alarms (setAndAllowWhileIdle):
 * Android may deliver them a few minutes late, but no exact-alarm permission
 * is needed. Each delivery schedules the next day; schedules are kept in
 * SharedPreferences so they are restored after a reboot or app update.
 * Scheduling the same id again replaces the previous alarm (no duplicates).
 */
class ReminderScheduler(private val context: Context) {

  private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
  private val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

  fun notificationsAllowed(): Boolean =
    NotificationManagerCompat.from(context).areNotificationsEnabled() &&
      (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
        PackageManager.PERMISSION_GRANTED)

  /** Daily at [hour]:[minute]; never earlier than [notBeforeMillis]. */
  fun scheduleDaily(id: Int, hour: Int, minute: Int, title: String, body: String, notBeforeMillis: Long) {
    val spec = JSONObject()
      .put("id", id).put("hour", hour).put("minute", minute)
      .put("title", title).put("body", body)
    prefs.edit().putString(key(id), spec.toString()).apply()
    setAlarm(id, nextDaily(hour, minute, maxOf(notBeforeMillis, System.currentTimeMillis())), title, body, true)
  }

  /** One reminder at [atMillis] (e.g. the end of a Focus Mode session). */
  fun scheduleOnce(id: Int, atMillis: Long, title: String, body: String) {
    prefs.edit().remove(key(id)).apply()
    setAlarm(id, atMillis, title, body, false)
  }

  fun cancel(id: Int) {
    prefs.edit().remove(key(id)).apply()
    alarms.cancel(pendingIntent(id, "", "", false))
  }

  /** Re-creates all daily alarms (after reboot / update). */
  fun restoreAll() {
    for ((k, value) in prefs.all) {
      if (!k.startsWith("daily_") || value !is String) continue
      val spec = runCatching { JSONObject(value) }.getOrNull() ?: continue
      setAlarm(
        spec.getInt("id"),
        nextDaily(spec.getInt("hour"), spec.getInt("minute"), System.currentTimeMillis()),
        spec.getString("title"),
        spec.getString("body"),
        true,
      )
    }
  }

  /** Called by the receiver after a daily reminder fired. */
  internal fun rescheduleNext(id: Int) {
    val spec = prefs.getString(key(id), null)?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return
    // Start from one minute later so the same slot is never reused today.
    setAlarm(
      id,
      nextDaily(spec.getInt("hour"), spec.getInt("minute"), System.currentTimeMillis() + 60_000L),
      spec.getString("title"),
      spec.getString("body"),
      true,
    )
  }

  private fun setAlarm(id: Int, atMillis: Long, title: String, body: String, daily: Boolean) {
    val pi = pendingIntent(id, title, body, daily)
    alarms.cancel(pi)
    alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pi)
  }

  private fun pendingIntent(id: Int, title: String, body: String, daily: Boolean): PendingIntent {
    val intent = Intent(context, ReminderReceiver::class.java)
      .setAction(ACTION_REMIND)
      .putExtra(EXTRA_ID, id)
      .putExtra(EXTRA_TITLE, title)
      .putExtra(EXTRA_BODY, body)
      .putExtra(EXTRA_DAILY, daily)
    return PendingIntent.getBroadcast(
      context,
      id,
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
  }

  private fun nextDaily(hour: Int, minute: Int, fromMillis: Long): Long {
    val c = Calendar.getInstance().apply {
      timeInMillis = fromMillis
      set(Calendar.HOUR_OF_DAY, hour)
      set(Calendar.MINUTE, minute)
      set(Calendar.SECOND, 0)
      set(Calendar.MILLISECOND, 0)
    }
    if (c.timeInMillis <= fromMillis) c.add(Calendar.DAY_OF_YEAR, 1)
    return c.timeInMillis
  }

  fun show(id: Int, title: String, body: String) {
    if (!notificationsAllowed()) return
    ensureChannel(context)
    val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
      ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    val content = launch?.let {
      PendingIntent.getActivity(context, id, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    val notification = NotificationCompat.Builder(context, CHANNEL_ID)
      .setSmallIcon(R.drawable.ic_stat_vivora)
      .setContentTitle(title)
      .setContentText(body)
      .setStyle(NotificationCompat.BigTextStyle().bigText(body))
      .setPriority(NotificationCompat.PRIORITY_DEFAULT)
      .setAutoCancel(true)
      .setContentIntent(content)
      .build()
    try {
      NotificationManagerCompat.from(context).notify(id, notification)
    } catch (_: SecurityException) {
      // Permission revoked between the check and the call.
    }
  }

  companion object {
    const val CHANNEL_ID = "vivora_reminders"
    const val ACTION_REMIND = "com.example.vivora.REMIND"
    const val EXTRA_ID = "id"
    const val EXTRA_TITLE = "title"
    const val EXTRA_BODY = "body"
    const val EXTRA_DAILY = "daily"
    const val REQUEST_NOTIFICATIONS = 7002
    private const val PREFS = "vivora_reminders"
    private fun key(id: Int) = "daily_$id"

    fun ensureChannel(context: Context) {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
      val manager = context.getSystemService(NotificationManager::class.java)
      if (manager.getNotificationChannel(CHANNEL_ID) == null) {
        manager.createNotificationChannel(
          NotificationChannel(CHANNEL_ID, "Reminders", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Daily log, study and Focus Mode reminders you turned on in Personal Digital Twin."
          },
        )
      }
    }

    fun requestPermission(activity: Activity): Boolean {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
      ActivityCompat.requestPermissions(
        activity,
        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
        REQUEST_NOTIFICATIONS,
      )
      return true
    }
  }
}

class ReminderReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action != ReminderScheduler.ACTION_REMIND) return
    val scheduler = ReminderScheduler(context)
    val id = intent.getIntExtra(ReminderScheduler.EXTRA_ID, 0)
    scheduler.show(
      id,
      intent.getStringExtra(ReminderScheduler.EXTRA_TITLE) ?: "Personal Digital Twin",
      intent.getStringExtra(ReminderScheduler.EXTRA_BODY) ?: "",
    )
    if (intent.getBooleanExtra(ReminderScheduler.EXTRA_DAILY, false)) {
      scheduler.rescheduleNext(id)
    }
  }
}

/** Restores daily reminders after a reboot or an app update. */
class ReminderBootReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    when (intent.action) {
      Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
        ReminderScheduler(context).restoreAll()
    }
  }
}
