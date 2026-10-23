package app.tomevoice.tomevoice_spike

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.ListView

/**
 * Which book a "Now reading" widget shows: the one read last (it follows
 * along), or one chosen here. Shown when the widget is added (optional) and
 * from the launcher's Reconfigure.
 */
class WidgetConfigActivity : Activity() {

    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        widgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        // Leaving without a choice keeps the widget following the last book.
        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        title = "Show on the widget"
        val books = Widgets.books(this)
        val labels = listOf("Continue listening (the book you read last)") + books.map { it.title }
        val list = ListView(this).apply {
            adapter = ArrayAdapter(this@WidgetConfigActivity, android.R.layout.simple_list_item_1, labels)
            setOnItemClickListener { _, _, position, _ ->
                Widgets.setBook(this@WidgetConfigActivity, widgetId, if (position == 0) null else books[position - 1].id)
                Widgets.refreshAll(this@WidgetConfigActivity)
                finish()
            }
        }
        setContentView(list)
    }
}
