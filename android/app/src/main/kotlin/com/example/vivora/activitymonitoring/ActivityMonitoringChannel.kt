package com.example.vivora.activitymonitoring

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handles the `vivora/activity_monitoring` channel for any Flutter engine:
 * the visible app (MainActivity) and the headless engine used by
 * [com.example.vivora.backgroundsync.BackgroundSyncWorker], so background
 * syncs use exactly the same capture code.
 */
object ActivityMonitoringChannel {
	fun handle(bridge: ActivityMonitoringBridge, call: MethodCall, result: MethodChannel.Result) {
		when (call.method) {
			"getPermissionSnapshot" -> result.success(bridge.getPermissionSnapshot())
			"getSyncMetadata" -> result.success(bridge.getSyncMetadata())
			"saveSyncMetadata" -> {
				@Suppress("UNCHECKED_CAST")
				val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
				bridge.saveSyncMetadata(arguments)
				result.success(null)
			}
	
			"openUsageAccessSettings" -> {
				bridge.openUsageAccessSettings()
				result.success(null)
			}
	
			"requestActivityPermission" -> {
				bridge.requestActivityPermission(
					onGranted = { result.success(true) },
					onDenied = { result.success(false) },
				)
			}
	
			"scheduleBackgroundSync" -> bridge.scheduleBackgroundSync { scheduled -> result.success(scheduled) }
			"removeBackgroundSync" -> {
				bridge.removeBackgroundSync()
				result.success(null)
			}
			"captureActivityRange" -> {
				@Suppress("UNCHECKED_CAST")
				val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
				val startMillis = (arguments["startMillis"] as? Number)?.toLong() ?: 0L
				val endMillis = (arguments["endMillis"] as? Number)?.toLong() ?: 0L
				result.success(bridge.captureActivityRange(startMillis, endMillis))
			}
	
			"getUsageDiagnostics" -> {
				@Suppress("UNCHECKED_CAST")
				val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
				val startMillis = (arguments["startMillis"] as? Number)?.toLong() ?: 0L
				val endMillis = (arguments["endMillis"] as? Number)?.toLong() ?: 0L
				result.success(bridge.getUsageDiagnostics(startMillis, endMillis))
			}
	
			else -> result.notImplemented()
		}
	}
}
