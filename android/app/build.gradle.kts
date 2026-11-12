plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "ink.contrast"
    compileSdk = 35

    defaultConfig {
        applicationId = "ink.contrast"
        minSdk = 26          // Android 8: drawing over other apps the modern way
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // For personal use (not the Play Store). Android installs an update over the old app only when both are signed
    // with the same key. The key is never kept in the repository: GitHub writes it from the repository's secret
    // ANDROID_KEYSTORE_B64 (password: ANDROID_KEYSTORE_PASSWORD) into CONTRAST_KEYSTORE. Without it, builds are signed
    // with a throwaway key: they work, but each new version must replace the old one by uninstalling it first.
    val keystore = System.getenv("CONTRAST_KEYSTORE")?.let { file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (keystore != null) create("personal") {
            storeFile = keystore
            storePassword = System.getenv("CONTRAST_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("CONTRAST_KEY_ALIAS") ?: "contrastink"
            keyPassword = System.getenv("CONTRAST_KEYSTORE_PASSWORD")
        }
    }

    buildTypes {
        val signing = if (keystore != null) signingConfigs.getByName("personal") else signingConfigs.getByName("debug")
        debug { signingConfig = signing }
        release {
            signingConfig = signing
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    lint { abortOnError = false }
}

dependencies {
    implementation(project(":core"))
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}
