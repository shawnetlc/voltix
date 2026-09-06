package com.voltix.app

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Installs a last-resort crash handler BEFORE anything else in the process.
 *
 * Android's startup order is: Application.attachBaseContext -> ContentProviders
 * (FirebaseInitProvider, FlutterFirebaseMessagingInitProvider, androidx.startup,
 * background_downloader's OpenFileProvider ...) -> Application.onCreate ->
 * MainActivity -> Flutter engine -> Dart.
 *
 * Anything that throws in that window kills the process before Flutter exists,
 * so no Dart-level error handling can ever see it, and TV launchers show no
 * crash dialog at all -- the symptom is simply "tap the icon, nothing happens".
 *
 * Hooking the handler here (the earliest point app code runs) captures those
 * failures and shows them on screen via VoltixCrashActivity, which runs in its
 * OWN process so it survives this one dying. A copy is also written to
 * <externalFilesDir>/voltix_crash.log.
 *
 * Every step is individually guarded: this class must never itself be the
 * reason the app fails to start.
 */
class VoltixApplication : Application() {

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        try {
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, error ->
                val report = try {
                    buildReport(error)
                } catch (t: Throwable) {
                    "Failed to render crash: $error"
                }

                try {
                    Log.e(TAG, report)
                } catch (_: Throwable) {
                }
                try {
                    writeToDisk(report)
                } catch (_: Throwable) {
                }
                try {
                    showOnScreen(report)
                } catch (_: Throwable) {
                }

                try {
                    previous?.uncaughtException(thread, error)
                } catch (_: Throwable) {
                }

                try {
                    Process.killProcess(Process.myPid())
                } catch (_: Throwable) {
                }
            }
        } catch (_: Throwable) {
            // A missing crash reporter is survivable; a crashing one is not.
        }
    }

    private fun buildReport(error: Throwable): String {
        val stack = StringWriter()
        error.printStackTrace(PrintWriter(stack))
        val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
        return buildString {
            append("Voltix startup crash\n")
            append(stamp).append('\n')
            append("device : ").append(Build.MANUFACTURER).append(' ')
                .append(Build.MODEL).append('\n')
            append("android: ").append(Build.VERSION.RELEASE)
                .append(" (sdk ").append(Build.VERSION.SDK_INT).append(")\n")
            append("abis   : ").append(Build.SUPPORTED_ABIS.joinToString()).append("\n\n")
            append(stack.toString())
        }
    }

    private fun writeToDisk(report: String) {
        val dir = getExternalFilesDir(null) ?: filesDir ?: return
        File(dir, "voltix_crash.log").writeText(report)
    }

    private fun showOnScreen(report: String) {
        val intent = Intent(this, VoltixCrashActivity::class.java)
        intent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TASK or
                Intent.FLAG_ACTIVITY_NO_ANIMATION
        )
        intent.putExtra(VoltixCrashActivity.EXTRA_DETAILS, report)
        startActivity(intent)
        // Give the other process a moment to come up before we die.
        try {
            Thread.sleep(1200)
        } catch (_: InterruptedException) {
        }
    }

    private companion object {
        const val TAG = "VoltixStartup"
    }
}
