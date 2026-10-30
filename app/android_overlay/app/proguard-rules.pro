# Release builds are shrunk by R8. PdfBox loads fonts, glyph lists and filters
# by name, so keep it whole rather than chase reflection one class at a time.
-keep class com.tom_roush.** { *; }
-dontwarn com.tom_roush.**
# Optional PdfBox codecs that are not on the classpath.
-dontwarn com.gemalto.jp2.**
-dontwarn org.bouncycastle.**
-dontwarn javax.xml.**
-dontwarn org.apache.commons.logging.**

# Our platform code is referenced from the manifest and the method channel.
-keep class app.tomevoice.** { *; }

# WorkManager (the check for new chapters with the app closed,
# NovelCheckWorker.kt) makes its Room database by reflection. R8 took that
# constructor away, and every launch crashed in androidx.startup with
# NoSuchMethodException: WorkDatabase_Impl.<init>.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { <init>(); }
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

# Tesseract4Android (OCR, Ocr.kt) ships no rules of its own. Its native code
# calls back into TessBaseAPI by name, and its classes hold native pointers;
# kept whole, as it is small (about 80 KB of classes).
-keep class com.googlecode.tesseract.android.** { *; }
-keep class com.googlecode.leptonica.android.** { *; }

# A missing optional class must not fail the release build; the code paths
# that need them (JPEG2000 images, encrypted PDFs) are not used for text.
-ignorewarnings
