import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// release 签名配置
//
// 密钥材料（keystore + 密码）**不入库**（见仓库根 .gitignore 的
// `*.jks` / `*.keystore` / `key.properties`，以及 AGENTS.md §12）。
// 本地/CI 想签正式包时，自行创建 `apps/spb_mobile/android/key.properties`，
// 格式见同目录的 `key.properties.example`。
//
// ## 为什么「缺文件」要回退而不是直接报错
//
// 直接报错会让**所有**没配密钥的人构建不了 release 包——包括只想跑
// `flutter build apk --release` 验证编译、以及还没拿到发布密钥的 CI。
// 回退到 debug 签名至少能产出可安装的包，但会打印醒目警告说明「这不是
// 可发布的包」。
//
// ## 为什么「文件存在但残缺」要直接失败
//
// 这两种情况的意图完全不同：
//   - 文件不存在 → 用户没打算签名，回退是合理的默认。
//   - 文件存在但缺字段 → 用户**明确打算**签名，只是配错了。此时静默回退
//     会产出一个 debug 签名的 APK，用户以为签好了、实际无法上架/无法覆盖
//     安装。这种「看起来成功」的失败必须变成硬错误。
// ---------------------------------------------------------------------------

/** 签名配置文件名（相对 `apps/spb_mobile/android/`）。 */
val keystorePropertiesFileName = "key.properties"

val keystorePropertiesFile = rootProject.file(keystorePropertiesFileName)
val keystoreProperties = Properties()
val hasKeystoreProperties = keystorePropertiesFile.exists()

if (hasKeystoreProperties) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

/** 必须全部非空，缺一个就说明配置残缺。 */
val requiredKeystoreKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val missingKeystoreKeys =
    requiredKeystoreKeys.filter { keystoreProperties.getProperty(it).isNullOrBlank() }
val canSignRelease = hasKeystoreProperties && missingKeystoreKeys.isEmpty()

if (hasKeystoreProperties && missingKeystoreKeys.isNotEmpty()) {
    throw GradleException(
        """
        |$keystorePropertiesFileName 存在但不完整，缺少：${missingKeystoreKeys.joinToString(", ")}
        |（文件位置：${keystorePropertiesFile.absolutePath}）
        |
        |请补全这四个键，或删掉该文件以回退到 debug 签名。
        |注意：这里**故意**不自动回退——否则你会得到一个 debug 签名的 APK
        |却以为已经签好了，直到上架/覆盖安装时才失败。
        |参考格式见同目录的 $keystorePropertiesFileName.example。
        """.trimMargin()
    )
}

if (!hasKeystoreProperties) {
    logger.warn(
        """
        |
        |======================================================================
        |  警告：未找到 $keystorePropertiesFileName，release 将使用 debug 签名
        |======================================================================
        |  查找位置：${keystorePropertiesFile.absolutePath}
        |
        |  产物**不可用于发布**（无法上架、无法覆盖安装正式包）。
        |  若要签正式包，复制 $keystorePropertiesFileName.example 为
        |  $keystorePropertiesFileName 并填入 keystore 信息。
        |
        |  这只是一条提示：构建会继续，以便本地验证编译 / CI 出可安装包。
        |======================================================================
        |
        """.trimMargin()
    )
}

android {
    namespace = "com.atjog.spb.spb_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // ## 为什么必须开 core library desugaring
        //
        // `flutter_local_notifications`（issue #21 的 OS 通知）在 Android 侧用了
        // `java.time` 等 Java 8+ API，而 `minSdk` 低于 26 时这些 API 在旧设备上
        // 不存在——插件因此声明 `coreLibraryDesugaring` 依赖，构建期强制要求
        // 宿主应用开启它。不开就**构建失败**：
        //
        //   Dependency ':flutter_local_notifications' requires core library
        //   desugaring to be enabled for :app.
        //
        // 这是插件的硬性要求（不是可选优化），故不能靠降级版本绕开。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.atjog.spb.spb_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 只在配置完整时创建。缺失时整个 release signingConfig 不存在，
        // buildTypes.release 会显式落到 debug（见下），而不是拿到一个半成品。
        if (canSignRelease) {
            create("release") {
                // 路径相对 `apps/spb_mobile/android/`（即 key.properties 所在目录），
                // 与 Flutter 官方文档里 `storeFile=../app/upload-keystore.jks`
                // 那种「相对 app 模块」的写法不同——这里用 rootProject 解析，
                // 因为 key.properties 本身就在 android/ 下，同目录引用更直观。
                // 绝对路径同样可用（Project.file 对绝对路径原样返回）。
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有完整配置用 release 签名，否则回退 debug（上面已打印警告）。
            signingConfig =
                if (canSignRelease) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
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
    // 与上面的 `isCoreLibraryDesugaringEnabled` 配套（缺一个都会构建失败）。
    //
    // 版本取 2.1.4：Android Gradle Plugin 8.x 兼容的最低稳定线附近；更高的
    // 2.1.x 也可用，但没必要追新（desugar 的 API 集不会因此变化）。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
