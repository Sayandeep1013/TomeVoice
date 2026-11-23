# Release builds are shrunk by R8. PdfBox-Android 2.0.27 is no longer kept
# whole (it was 82% of what R8 had to keep, the Play "DEX optimisation"
# score's main cost): it reads fonts, glyph lists, CMaps and AFM files by
# path, not by class name, and ships its own rules for the two places it
# uses reflection (SecurityHandler constructors, documentinterchange),
# which R8 applies (seen in configuration.txt). PdfText.kt catches
# InvalidPasswordException by type for the same reason.
-dontwarn com.tom_roush.**
# Optional PdfBox codecs that are not on the classpath.
-dontwarn com.gemalto.jp2.**
-dontwarn org.bouncycastle.**
-dontwarn javax.xml.**
-dontwarn org.apache.commons.logging.**

# Our platform code (app.tomevoice.**) is not kept whole any more: nothing
# in it is found by name. Its activities, services, receivers (the widgets,
# which Widgets.kt also makes with their no-argument constructors) and
# providers are kept by the rules AAPT writes from the manifest; its two
# workers by the WorkManager rule below (WorkManager makes them by name);
# everything else is reached from code (the method channels call into it,
# it calls Flutter's and Android's APIs), so R8 shrinks and renames it like
# any code. No JNI calls into it, and it uses no reflection.

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

# jump3r (saving as MP3, Mp3Writer in AudioExport.kt) needs no keep rules:
# plain Java with no reflection and no native code, which R8 shrinks to the
# encoder like our own code. Its wrapper and its command line (LameEncoder,
# Main), which nothing here uses, name javax.sound and java.beans, which
# Android has not.
-dontwarn javax.sound.sampled.**
-dontwarn java.beans.**

# -ignorewarnings is gone: every class a library names but the app does not
# have is let pass above by name, so a new one fails the build instead of a
# feature at run time.
