import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is read from android/key.properties when present. That file
// is gitignored (never commit a keystore). When it is absent we fall back to
// the debug signing config so `flutter build apk` always works locally / in CI.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.vedastro.sleep_time"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.vedastro.sleep_time"
        // Pin the SDK floor/ceiling explicitly (override Flutter defaults):
        // minSdk 26 — NotificationChannel + JobScheduler era, our baseline.
        // targetSdk 35 — Android 15, where the FGS/boot/exact-alarm rules we
        // build against are enforced.
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // No keystore on this machine — debug-sign so the build still
                // succeeds. Not for Play upload; supply key.properties for that.
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // WorkManager: schedules the expedited boot-recovery job that re-arms the
    // bedtime alarms after a reboot (BOOT_COMPLETED cannot start a specialUse
    // FGS directly on Android 15).
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    // LocalBroadcastManager: in-process bridge from the service to the
    // MainActivity EventChannel so Dart can mirror native guardian state.
    implementation("androidx.localbroadcastmanager:localbroadcastmanager:1.1.0")
}
