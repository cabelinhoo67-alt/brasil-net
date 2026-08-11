plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "br.com.tunnelsystem.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "br.com.tunnelsystem.app"
        // minSdk = flutter.minSdkVersion (24 = Android 7.0 Nougat): e o MINIMO
        // que o Flutter 3.44 + os plugins atuais suportam. A task
        // ReleaseMinSdkCheck rejeita minSdk < 23, e o plugin
        // shared_preferences_android (versao atual) exige 24 no merge do
        // manifest. Tentar 21/23 quebra o build. Isso e consistente com os
        // splits 1.2.2 ja publicados (2007), gerados com o mesmo Flutter.
        // O codigo nativo em TunnelVpnService/OverlayService ja tem as guardas
        // de versao necessarias para APIs acima de 24 (NotificationChannel so
        // em API 26+, NotificationCompat para o resto, stopForeground).
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// androidx.core (FileProvider) e androidx.annotation (@Keep) chegam
// transitivos do Flutter, mas depender disso e fragil — uma bump do
// embedding pode remove-los. Declaramos explicitamente.
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.annotation:annotation:1.8.2")
}
