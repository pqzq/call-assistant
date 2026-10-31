import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名配置：本地/CI 若提供 android/key.properties 就用它签名 release，
// 没有则回退到 debug 签名，保证任何环境都能构建出可安装的包。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.callassistant.call_assistant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.callassistant.call_assistant"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // record 插件要求 24+（Android 7.0），否则构建直接失败
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
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // CI 用 Secrets 还原的正式密钥；本地没配置时用 debug 签名，方便直接出包自测
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // Live2D 的模型 / 贴图资源不做 APK 压缩。
    //
    // Cubism 通过 AAssetManager 读这些文件：压缩后必须先解压到内存，
    // 大文件（.moc3 400KB+、贴图 2MB+）既费时又吃内存；某些 ROM 上
    // openFd()（走 mmap）对压缩资源还会直接失败 —— 表现为
    // 「模型加载成功但贴图异常 / 白模」。
    //
    // 代价是 APK 大约多 0.5MB（这些文件本来就难压缩，png 已默认不压）。
    androidResources {
        noCompress += listOf(
            "moc3",
            "model3.json",
            "motion3.json",
            "physics3.json",
            "exp3.json",
            "pose3.json",
            "cdi3.json",
            "png",
        )
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
