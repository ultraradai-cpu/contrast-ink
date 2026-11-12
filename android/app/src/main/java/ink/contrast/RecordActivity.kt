package ink.contrast

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle

/** Invisible: shows Android's "start recording?" question, hands the answer to the service, and goes. */
class RecordActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return   // turned while Android asks: the question is already up, don't ask twice
        val mpm = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), 1)
    }

    @Deprecated("Activity result API: the platform one, no extra library")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        // still on screen here: Android 14 lets a recording start only while the app is in front
        if (resultCode == RESULT_OK && data != null) InkService.running?.startRecording(resultCode, data)
        finish()
    }
}
