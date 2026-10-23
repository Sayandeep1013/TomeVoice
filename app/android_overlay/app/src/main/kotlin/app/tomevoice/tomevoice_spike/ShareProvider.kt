package app.tomevoice.tomevoice_spike

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Hands a picture made in the app (a quote card) to the app it is shared
 * with, read-only and only for that share.
 *
 * Android will not let a file path cross apps; a content:// address served
 * from here does. Only files in cache/share are served, so nothing else in
 * the app's storage can be reached through it. Written rather than taken
 * from androidx (FileProvider) to add no dependency.
 */
class ShareProvider : ContentProvider() {

    companion object {
        fun dir(cache: File): File = File(cache, "share").apply { mkdirs() }

        fun uriFor(authority: String, file: File): Uri =
            Uri.Builder().scheme("content").authority(authority).appendPath(file.name).build()
    }

    private fun fileFor(uri: Uri): File {
        val ctx = context ?: throw FileNotFoundException()
        val name = uri.lastPathSegment ?: throw FileNotFoundException()
        val base = dir(ctx.cacheDir)
        val file = File(base, name)
        if (file.canonicalFile.parentFile != base.canonicalFile || !file.isFile) {
            throw FileNotFoundException(name)
        }
        return file
    }

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
        ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY)

    override fun getType(uri: Uri): String =
        if (uri.lastPathSegment?.endsWith(".png") == true) "image/png" else "application/octet-stream"

    // Some apps ask for the name and size before reading.
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val file = fileFor(uri)
        val cursor = MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE))
        cursor.addRow(arrayOf<Any>(file.name, file.length()))
        return cursor
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
