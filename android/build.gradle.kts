group = "tech.velorion.qvac_flutter"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "tech.velorion.qvac_flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
        ndk {
            // The worker's addons are only built for 64-bit ARM.
            abiFilters += "arm64-v8a"
        }
    }

    androidResources {
        // The worker bundle is read whole at start; compressing it only costs time.
        noCompress += "bundle"
    }

}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // BareKit's Java classes. Its .so files and the worker sit in src/main/jniLibs and assets,
    // put there by tool/worker (npm run build).
    implementation(files("libs/bare-kit.jar"))
}
