package tech.velorion.qvac_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import to.holepunch.bare.kit.IPC
import to.holepunch.bare.kit.Worklet
import java.nio.ByteBuffer

/** Runs the QVAC worker in a BareKit worklet and passes its IPC bytes to Dart. */
class QvacFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())

    private var worklet: Worklet? = null
    private var ipc: IPC? = null
    private var sink: EventChannel.EventSink? = null
    // Bytes that arrived before Dart started listening.
    private val early = ArrayList<ByteArray>()
    private val outbox = ArrayDeque<ByteArray>()
    private var writing = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "qvac_flutter")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "qvac_flutter/ipc")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> try {
                start(call.argument<String>("homeDir"))
                result.success(null)
            } catch (e: Exception) {
                result.error("start_failed", e.message, null)
            }
            "write" -> {
                val bytes = call.arguments as? ByteArray
                    ?: return result.error("bad_args", "write needs bytes", null)
                outbox.addLast(bytes)
                flush()
                result.success(null)
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(homeDir: String?) {
        check(worklet == null) { "The QVAC worker is already running" }
        val home = homeDir ?: context.filesDir.absolutePath
        val worklet = Worklet(Worklet.Options())
        try {
            // Same argument shape as QVAC's Kotlin SDK: the JSON config must be third.
            val args = arrayOf("qvac_flutter", "worker.bundle", JSONObject().put("HOME_DIR", home).toString())
            context.assets.open("worker.bundle").use { worklet.start("/worker.bundle", it, args) }
        } catch (e: Exception) {
            worklet.terminate()
            throw e
        }
        this.worklet = worklet
        ipc = IPC(worklet)
        read()
    }

    private fun read() {
        val current = ipc ?: return
        current.read { data, error ->
            main.post {
                if (ipc !== current) return@post
                when {
                    error != null -> sink?.error("ipc_error", error.message, null)
                    data == null -> sink?.endOfStream()
                    else -> {
                        emit(data.toByteArray())
                        read()
                    }
                }
            }
        }
    }

    private fun emit(bytes: ByteArray) {
        sink?.success(bytes) ?: early.add(bytes)
    }

    // One write at a time, so frames reach the worker in order.
    private fun flush() {
        val current = ipc ?: return
        if (writing || outbox.isEmpty()) return
        writing = true
        val bytes = outbox.removeFirst()
        val buffer = ByteBuffer.allocateDirect(bytes.size).put(bytes)
        buffer.flip()
        current.write(buffer) { error ->
            main.post {
                writing = false
                if (error != null) sink?.error("ipc_error", error.message, null)
                flush()
            }
        }
    }

    // Dart sends __shutdown__ first; terminating without it crashes the next start.
    private fun stop() {
        ipc?.close()
        ipc = null
        worklet?.terminate()
        worklet = null
        outbox.clear()
        early.clear()
        writing = false
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        early.forEach { events.success(it) }
        early.clear()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun ByteBuffer.toByteArray(): ByteArray {
        val out = ByteArray(remaining())
        get(out)
        return out
    }
}
