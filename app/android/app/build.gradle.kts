import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material lives outside the repo (see tools/setup-signing.sh).
val keysDir = System.getenv("COUPLE_LEDGER_KEYS") ?: "${System.getProperty("user.home")}/.couple-ledger-keys"
val releaseKeystore = file("$keysDir/release.jks")
val keyPasswords = Properties().apply {
    val f = file("$keysDir/passwords.env")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.k1ngmew.liangrenzhang"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.k1ngmew.liangrenzhang"
        // foreground services and notification channels need Android 8+
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (releaseKeystore.exists()) {
                storeFile = releaseKeystore
                storePassword = keyPasswords.getProperty("ANDROID_STORE_PASSWORD")
                keyAlias = "couple-ledger"
                keyPassword = keyPasswords.getProperty("ANDROID_STORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeystore.exists()) "release" else "debug")
        }
    }
}

flutter {
    source = "../.."
}
