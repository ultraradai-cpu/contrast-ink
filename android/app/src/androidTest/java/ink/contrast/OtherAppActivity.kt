package ink.contrast

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView

/**
 * A stand-in for the app a lecturer draws over (slides, a PDF, a browser): its own package, so the overlay is
 * "another app's" window to Android. Its lower half is one big button that says when it was tapped.
 *
 * [EXTRA_BACKGROUND]: the slide's background colour (white unless given): a dark slide, even exactly the toolbar's
 * own colour, must not be taken for the toolbar by the recorder.
 */
class OtherAppActivity : Activity() {
    companion object {
        const val EXTRA_BACKGROUND = "ink.contrast.test.BACKGROUND"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val background = intent.getIntExtra(EXTRA_BACKGROUND, Color.WHITE)
        val dark = Color.red(background) + Color.green(background) + Color.blue(background) < 3 * 128
        window.decorView.setBackgroundColor(background)
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(background) }
        col.addView(TextView(this).apply {
            text = "A slide in another app"
            textSize = 28f
            setTextColor(if (dark) Color.LTGRAY else Color.BLACK)
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        val button = TextView(this).apply {
            text = "Not tapped"
            textSize = 28f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(0x25, 0x63, 0xEB))
            gravity = Gravity.CENTER
            setOnClickListener { text = "Tapped" }
        }
        col.addView(button, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(col)
    }
}
