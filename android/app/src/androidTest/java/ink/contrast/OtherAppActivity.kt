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
 */
class OtherAppActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.WHITE) }
        col.addView(TextView(this).apply {
            text = "A slide in another app"
            textSize = 28f
            setTextColor(Color.BLACK)
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
