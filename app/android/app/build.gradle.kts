import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing, when a keystore is configured.
//
// `android/key.properties` is deliberately not in the repository — it names a
// keystore path and holds its passwords. Without it the release build falls
// back to the debug key so that `flutter run --release` still works on a fresh
// clone, and CI can produce an installable artifact without holding the
// signing key. See docs/ANDROID.md for the four lines it needs.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseKeystore = keystorePropertiesFile.exists()

android {
    namespace = "com.dmgworkshop.coldwater"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dmgworkshop.coldwater"

        // Pinned rather than inherited so a Flutter upgrade cannot silently
        // raise the floor. 24 is Flutter's own minimum; file_picker needs 21,
        // and pdfium — which does the on-device text extraction — needs 21.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion

        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (hasReleaseKeystore) "release" else "debug",
            )

            // Left off deliberately. Flutter's Dart code is already tree-shaken
            // and AOT-compiled; enabling R8 over the Java/Kotlin side buys
            // little here and breaks reflection-based plugin code in ways that
            // only show up at runtime, not at build time. proguard-rules.pro
            // holds the rules this app would need if that trade ever changes.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
