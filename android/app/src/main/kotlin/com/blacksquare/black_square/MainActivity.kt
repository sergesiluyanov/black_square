package com.blacksquare.black_square

import android.content.Intent
import android.os.Bundle
import com.hiennv.flutter_callkit_incoming.CallkitConstants
import com.hiennv.flutter_callkit_incoming.FlutterCallkitIncomingPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.HashMap

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "black_square/call_launch"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getLaunchIntentCallData") {
                val data = getLaunchIntentCallData()
                result.success(data)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    private fun getLaunchIntentCallData(): Map<String, String>? {
        val intent = intent ?: return null
        val action = intent.action ?: return null
        // Plugin uses "com.hiennv.flutter_callkit_incoming.ACTION_CALL_ACCEPT" when launching via TransparentActivity
        val acceptAction = CallkitConstants.ACTION_CALL_ACCEPT
        val acceptActionWithPrefix = "${packageName}.${CallkitConstants.ACTION_CALL_ACCEPT}"
        if (action != acceptAction && action != acceptActionWithPrefix) return null

        val bundle = intent.getBundleExtra(FlutterCallkitIncomingPlugin.EXTRA_CALLKIT_CALL_DATA)
            ?: return null

        val callId = bundle.getString(CallkitConstants.EXTRA_CALLKIT_ID)
            ?: (bundle.getSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA) as? HashMap<*, *>)?.get("callId")?.toString()
        val from = bundle.getString(CallkitConstants.EXTRA_CALLKIT_HANDLE)
            ?: (bundle.getSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA) as? HashMap<*, *>)?.get("from")?.toString()

        if (callId.isNullOrEmpty() || from.isNullOrEmpty()) return null

        val fromName = bundle.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER)
            ?: (bundle.getSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA) as? HashMap<*, *>)?.get("fromName")?.toString()

        return mutableMapOf(
            "callId" to callId,
            "from" to from,
        ).apply { if (fromName != null) put("fromName", fromName) }
    }
}
