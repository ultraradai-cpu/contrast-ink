package ink.contrast

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle

/** Invisible: shows Android's "start recording?" question, hands the answer to the service, and goes. */
class RecordActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return   // turned while Android asks: the question is already up, don't ask twice
        val mpm = getSystemService(MediaProjectionManager::class.java)
        // Android 14+: the presenter chooses "A single app" (the slides app: the toolbar stays out of the video) or
        // "Entire screen". Asked for explicitly, so a phone maker's default can't take the choice away.
        val ask = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
            mpm.createScreenCaptureIntent(MediaProjectionConfig.createConfigForUserChoice())
        else mpm.createScreenCaptureIntent()
        @Suppress("DEPRECATION")
        startActivityForResult(ask, 1)
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
