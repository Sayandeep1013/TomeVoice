package app.tomevoice.tomevoice_spike

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Where "Open with TomeVoice" and "Share to TomeVoice" land. It lives for an
 * instant in the other app's task and hands what it was given to the one
 * TomeVoice, in TomeVoice's own task.
 *
 * Opened there directly, MainActivity became a second TomeVoice: a file
 * manager asks for a result when it opens a file, and an activity started
 * for a result joins the caller's task whatever its launch mode. Each copy
 * had its own engine and its own library in memory, so one could write over
 * a book the other had just added; and Back at the library then put the
 * file manager behind as well, instead of returning to it.
 */
class OpenActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val given = intent
        if (given != null) {
            // A new intent rather than a copy: the caller's flags (a result
            // to forward among them) would start a second TomeVoice again.
            val forward = Intent(given.action).apply {
                setClass(this@OpenActivity, MainActivity::class.java)
                setDataAndType(given.data, given.type)
                clipData = given.clipData
                given.extras?.let { putExtras(it) }
                // The file's read permission goes along with it.
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            try {
                startActivity(forward)
            } catch (e: Exception) {
                // Nothing to open it with; the caller stays as it was.
            }
        }
        finish()
    }
}
