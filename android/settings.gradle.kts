pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    // AGP 9.x bundles built-in Kotlin, but Flutter < 3.47 (CI runs 3.44.8)
    // requires the classic Kotlin Gradle plugin. android.builtInKotlin=false
    // in gradle.properties opts out of built-in Kotlin so applying the
    // kotlin-android plugin below stays valid.
    id("org.jetbrains.kotlin.android") version "2.4.10" apply false
}

include(":app")
