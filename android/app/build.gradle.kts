plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.proxy_app_test"
    compileSdk = flutter.compileSdkVersion
    // Версия прибита гвоздями, а не взята из flutter.ndkVersion: так видно,
    // какой NDK обязан стоять на машине. Значение — самое высокое из
    // затребованных: плагины `file_selector_android` и
    // `shared_preferences_android` просят 28.2, и Flutter об этом прямо
    // сообщает при сборке. Версии NDK обратно совместимы, поэтому берётся
    // старшая. Ядро приложения (`silacore.aar`) собрано отдельно, на 27.3, и
    // от этой настройки не зависит — оно приходит уже скомпилированным.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // applicationId НЕ меняем, хотя он и выглядит как заготовка. На Android
        // это ключ к папке данных приложения: сменить его — то же самое, что на
        // Windows сменить ProductName, на чём однажды уже потеряли все профили
        // пользователя (подробности в CLAUDE.md). Отображаемое имя задаётся
        // через android:label в манифесте, а не отсюда.
        applicationId = "com.example.proxy_app_test"
        // 24, а не значение Flutter: ядро в silacore.aar собрано gomobile с
        // -androidapi 24, и на более старой системе оно попросту не загрузится.
        // Это Android 7, то есть 2016 год — отсекаются только совсем древние.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Список архитектур здесь НЕ задаётся, и это осознанно.
        //
        // Он был бы избыточен: в `silacore.aar` лежат ровно arm64-v8a,
        // armeabi-v7a и x86_64, и взять что-то ещё Gradle неоткуда. Зато
        // заданный вручную `abiFilters` несовместим с раздельной сборкой
        // (`--split-per-abi`), которой собираются файлы для раздачи:
        //
        //   Conflicting configuration: 'armeabi-v7a,arm64-v8a,x86_64' in ndk
        //   abiFilters cannot be present when splits abi filters are set
        //
        // Один общий APK со всеми архитектурами весит 214 МБ, раздельные —
        // около 80 каждый. Для файла, который человек скачивает на телефон,
        // разница существенная.
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // Ядро: sing-box (libbox) и обёртка над Xray в одной библиотеке. Почему в
    // одной, а не двумя — см. комментарий в mobile/go.mod: gomobile даёт каждой
    // свой рантайм Go под одинаковым именем файла, и две библиотеки в одном APK
    // конфликтуют.
    implementation(files("libs/silacore.aar"))
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
