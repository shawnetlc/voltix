package com.voltix.app

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.util.TypedValue
import android.widget.ScrollView
import android.widget.TextView

/**
 * Displays a startup crash on the device. Declared with android:process=":crash"
 * so it lives in a separate process and stays up after the main process dies.
 */
class VoltixCrashActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val details = try {
            intent?.getStringExtra(EXTRA_DETAILS)
        } catch (t: Throwable) {
            null
        } ?: "No crash details were captured."

        val body = TextView(this).apply {
            setTextColor(Color.parseColor("#FF8A80"))
            setPadding(48, 48, 48, 48)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
            text = details
        }

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor("#1A0000"))
            isFillViewport = true
            addView(body)
        }

        setContentView(scroll)
    }

    companion object {
        const val EXTRA_DETAILS = "voltix_crash_details"
    }
}
