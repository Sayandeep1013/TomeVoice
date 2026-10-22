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

# A missing optional class must not fail the release build; the code paths
# that need them (JPEG2000 images, encrypted PDFs) are not used for text.
-ignorewarnings
