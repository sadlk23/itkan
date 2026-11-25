import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingPath = providers.environmentVariable("ITKAN_SIGNING_PROPERTIES").orNull
val signingFile = rootProject.file(signingPath ?: "key.properties")
val uploadKey = if (signingFile.isFile) {
    Properties().apply { signingFile.inputStream().use { load(it) } }
} else {
    require(signingPath == null) { "ITKAN_SIGNING_PROPERTIES must point to an existing properties file." }
    null
}
val localRelease = providers.environmentVariable("ITKAN_LOCAL_RELEASE").orNull == "true"

android {
    namespace = "com.itkan.my_fridge"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.itkan.my_fridge"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        uploadKey?.let { credentials ->
            create("upload") {
                fun property(name: String): String = requireNotNull(credentials.getProperty(name)) {
                    "Missing $name in the Android signing properties."
                }
                val path = File(property("storeFile"))
                storeFile = if (path.isAbsolute) path else signingFile.resolveSibling(path)
                storePassword = property("storePassword")
                keyAlias = property("keyAlias")
                keyPassword = property("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            signingConfig = when {
                localRelease -> signingConfigs.getByName("debug")
                uploadKey != null -> signingConfigs.getByName("upload")
                else -> null
            }
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

dependencies {
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
}
