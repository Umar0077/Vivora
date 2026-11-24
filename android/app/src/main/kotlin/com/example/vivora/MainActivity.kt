package com.example.vivora

import com.example.vivora.activitymonitoring.ActivityMonitoringBridge
import com.example.vivora.activitymonitoring.ActivityMonitoringChannel
import com.example.vivora.backgroundsync.AppVisibility
import com.example.vivora.backgroundsync.BackgroundSyncScheduler
import com.example.vivora.backgroundsync.TrackingFlag
import com.example.vivora.reminders.ReminderScheduler
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private var activityMonitoringBridge: ActivityMonitoringBridge? = null
	private var pendingNotificationResult: MethodChannel.Result? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		activityMonitoringBridge = ActivityMonitoringBridge(this, this)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vivora/activity_monitoring")
			.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
				val bridge = activityMonitoringBridge
				if (bridge == null) {
					result.error("bridge_unavailable", "Activity bridge is not ready.", null)
					return@setMethodCallHandler
				}

				ActivityMonitoringChannel.handle(bridge, call, result)
			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vivora/background_sync")
			.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
				when (call.method) {
					"schedule" -> {
						BackgroundSyncScheduler.schedule(applicationContext)
						result.success(null)
					}
					"cancel" -> {
						BackgroundSyncScheduler.cancel(applicationContext)
						result.success(null)
					}
					"setTrackingEnabled" -> {
						@Suppress("UNCHECKED_CAST")
						val args = call.arguments as? Map<String, Any?> ?: emptyMap()
						val enabled = args["enabled"] == true
						TrackingFlag.set(applicationContext, enabled, args["uid"] as? String)
						if (!enabled) {
							// OFF: no background job and no movement updates.
							BackgroundSyncScheduler.cancel(applicationContext)
							try {
								activityMonitoringBridge?.removeBackgroundSync()
							} catch (error: Exception) {
								// Play services unavailable; the receiver ignores samples anyway.
							}
						}
						result.success(null)
					}
					else -> result.notImplemented()
				}
			}

		val reminders = ReminderScheduler(applicationContext)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vivora/reminders")
			.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
				@Suppress("UNCHECKED_CAST")
				val args = call.arguments as? Map<String, Any?> ?: emptyMap()
				fun int(key: String) = (args[key] as? Number)?.toInt() ?: 0
				fun text(key: String) = args[key] as? String ?: ""
				when (call.method) {
					"notificationsAllowed" -> result.success(reminders.notificationsAllowed())
					"requestNotificationPermission" -> {
						if (reminders.notificationsAllowed()) {
							result.success(true)
						} else if (pendingNotificationResult == null && ReminderScheduler.requestPermission(this)) {
							pendingNotificationResult = result
						} else {
							result.success(false)
						}
					}
					"scheduleDaily" -> {
						reminders.scheduleDaily(
							int("id"), int("hour"), int("minute"), text("title"), text("body"),
							(args["notBeforeMillis"] as? Number)?.toLong() ?: 0L,
						)
						result.success(null)
					}
					"scheduleOnce" -> {
						reminders.scheduleOnce(
							int("id"), (args["atMillis"] as? Number)?.toLong() ?: 0L, text("title"), text("body"),
						)
						result.success(null)
					}
					"cancel" -> {
						reminders.cancel(int("id"))
						result.success(null)
					}
					else -> result.notImplemented()
				}
			}
	}

	override fun onResume() {
		super.onResume()
		AppVisibility.isForeground = true
	}

	override fun onPause() {
		AppVisibility.isForeground = false
		super.onPause()
	}

	override fun onRequestPermissionsResult(
		requestCode: Int,
		permissions: Array<out String>,
		grantResults: IntArray,
	) {
		if (activityMonitoringBridge?.onRequestPermissionsResult(requestCode, grantResults) == true) {
			return
		}
		if (requestCode == ReminderScheduler.REQUEST_NOTIFICATIONS) {
			pendingNotificationResult?.success(
				grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED,
			)
			pendingNotificationResult = null
			return
		}
		super.onRequestPermissionsResult(requestCode, permissions, grantResults)
	}
}
