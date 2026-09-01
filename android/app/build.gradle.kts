import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load keystore properties for local builds
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.zarz.spotiflac"
    compileSdk = 35
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    defaultConfig {
        applicationId = "com.zarz.spotiflac"
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            ndk {
                debugSymbolLevel = "FULL"
            }
        }

        getByName("profile") {
            ndk {
                debugSymbolLevel = "FULL"
            }
        }

        release {
            // For local builds: use release signing if key.properties exists
            // For CI builds: APK is signed by GitHub Action after build
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Minification disabled to avoid R8 issues with Go AAR + FFmpeg + Java 17
            // Enable later with thorough testing. Proguard rules kept for reference.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            ndk {
                debugSymbolLevel = "FULL"
            }
        }
    }
    
    // ABI filtering is handled entirely by Flutter:
    //   * --split-per-abi     : produces one APK per ABI
    //   * --target-platform   : restricts the ABIs (android-arm, android-arm64)
    // Do NOT add an ndk.abiFilters block here — it conflicts with the
    // splits that --split-per-abi enables and breaks the release build
    // ("conflicting configuration in ndk abiFilters cannot be present when
    //  splits abi filters are set").
}

flutter {
    source = "../.."
}

repositories {
    flatDir {
        dirs("libs")
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    
    // Include all AAR and JAR files from libs folder
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.jar", "*.aar"))))
    
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.activity:activity-ktx:1.13.0")
    implementation("com.google.android.gms:play-services-auth-blockstore:16.4.0")

    // NativeDownloadFinalizer imports FFmpegKit APIs directly. The Flutter
    // plugin owns the runtime AAR; compileOnly avoids packaging it twice here.
    compileOnly("com.antonkarpenko:ffmpeg-kit-full:2.2.1")

    testImplementation("junit:junit:4.13.2")
}
