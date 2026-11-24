package com.example.vivora.backgroundsync

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.example.vivora.activitymonitoring.ActivityMonitoringBridge
import com.example.vivora.activitymonitoring.ActivityMonitoringChannel
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The "Automatic Activity Tracking" switch as seen by native code, written by
 * Dart (ActivityTrackingController) whenever it changes. Native collectors
 * check it themselves, so a stale WorkManager job or a delayed broadcast can
 * never collect while the switch is OFF, even before Dart has started.
 * Absent = OFF (privacy default).
 */
object TrackingFlag {
  private const val PREFS = "vivora_tracking_flag"

  fun set(context: Context, enabled: Boolean, uid: String?) {
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
      .putBoolean("enabled", enabled && uid != null)
      .putString("uid", uid)
      .commit()
  }

  fun isEnabled(context: Context): Boolean =
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("enabled", false)
}

/** Whether a Vivora screen is visible (set by MainActivity). */
object AppVisibility {
  @Volatile
  var isForeground: Boolean = false
}

/**
 * Background activity sync with Android WorkManager.
 *
 * WorkManager's shortest periodic interval is 15 minutes, and Android decides
 * the exact run time (Doze, App Standby buckets and manufacturer battery
 * savers such as MIUI can delay or skip runs). There is no exact 5-minute
 * background guarantee and none is faked here: while the app is open, the
 * Dart AutoSyncCoordinator syncs every 5 minutes instead.
 */
object BackgroundSyncScheduler {
  const val UNIQUE_WORK = "vivora_activity_sync"
  private const val TAG = "VivoraBackgroundSync"

  /** One unique periodic job; calling again keeps the existing one (KEEP). */
  fun schedule(context: Context) {
    if (!TrackingFlag.isEnabled(context)) return
    val request = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(15, TimeUnit.MINUTES)
      .setConstraints(
        Constraints.Builder()
          // Capturing works offline, but the result has to be uploaded.
          .setRequiredNetworkType(NetworkType.CONNECTED)
          .setRequiresBatteryNotLow(true)
          .build(),
      )
      .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 2, TimeUnit.MINUTES)
      .build()
    WorkManager.getInstance(context).enqueueUniquePeriodicWork(
      UNIQUE_WORK,
      ExistingPeriodicWorkPolicy.KEEP,
      request,
    )
    Log.d(TAG, "Periodic background sync registered")
  }

  fun cancel(context: Context) {
    WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_WORK)
  }
}

/**
 * Runs one sync by starting a short-lived headless Flutter engine at the
 * Dart entry point `backgroundSyncMain`, which uses the same ActivitySyncService
 * as the app (same capture, categories and idempotent Firestore write), so
 * Kotlin never duplicates the Dart calculations.
 */
class BackgroundSyncWorker(context: Context, params: WorkerParameters) :
  Worker(context, params) {

  override fun doWork(): Result {
    // Tracking switched OFF (or never ON): collect nothing and make sure the
    // job does not come back.
    if (!TrackingFlag.isEnabled(applicationContext)) {
      BackgroundSyncScheduler.cancel(applicationContext)
      return Result.success()
    }
    // The app's own 5-minute schedule is running; avoid a parallel sync.
    if (AppVisibility.isForeground) return Result.success()

    val done = CountDownLatch(1)
    val ok = AtomicBoolean(false)
    val main = Handler(Looper.getMainLooper())
    var engine: FlutterEngine? = null

    main.post {
      try {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val flutterEngine = FlutterEngine(applicationContext)
        engine = flutterEngine
        val bridge = ActivityMonitoringBridge(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "vivora/activity_monitoring")
          .setMethodCallHandler { call, result ->
            ActivityMonitoringChannel.handle(bridge, call, result)
          }
        MethodChannel(messenger, "vivora/background_sync")
          .setMethodCallHandler { call, result ->
            when (call.method) {
              "done" -> {
                ok.set(call.arguments == true)
                result.success(null)
                done.countDown()
              }
              // The headless engine must not (re)schedule itself.
              else -> result.success(null)
            }
          }
        flutterEngine.dartExecutor.executeDartEntrypoint(
          DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundSyncMain"),
        )
      } catch (error: Throwable) {
        Log.w(TAG, "Background sync could not start: ${error.message}")
        done.countDown()
      }
    }

    val finished = done.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)
    main.post { engine?.destroy() }
    return if (finished && ok.get()) Result.success() else Result.retry()
  }

  companion object {
    private const val TAG = "VivoraBackgroundSync"
    private const val TIMEOUT_SECONDS = 90L
  }
}
