# Rules this app would need if R8 is ever enabled for the release build.
#
# Not currently applied — `isMinifyEnabled` is false in build.gradle.kts, and
# the reasoning is recorded there. Kept so that turning it on is a one-line
# change rather than an afternoon of chasing NoSuchMethodError at runtime.

# Flutter's own embedding, loaded reflectively by the generated registrant.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# pdfium is reached over FFI through Dart native assets. The Java side is
# thin, but the loader looks the library up by name.
-keep class org.pdfium.** { *; }

# flutter_secure_storage delegates to AndroidX security-crypto, which
# instantiates its key providers reflectively.
-keep class androidx.security.crypto.** { *; }

# file_picker's activity result plumbing.
-keep class dev.flutter.plugins.filepicker.** { *; }
