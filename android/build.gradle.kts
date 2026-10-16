import java.net.URI
import java.security.MessageDigest

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

// Native binaries: a local build from tool/worker if there is one, else the GitHub release.
// Set qvacBinariesUrl in gradle.properties to fetch the release zip from somewhere else.
val nativeDir: File = if (file("src/main/jniLibs").isDirectory) projectDir else fetchRelease()

fun fetchRelease(): File {
    @Suppress("UNCHECKED_CAST")
    val release = groovy.json.JsonSlurper().parse(file("release.json")) as Map<String, String>
    val sha256 = release.getValue("sha256")
    val dir = layout.buildDirectory.dir("qvac-binaries/$sha256").get().asFile
    if (File(dir, "libs/bare-kit.jar").isFile) return dir
    val url = (findProperty("qvacBinariesUrl") as String?) ?: release.getValue("url")
    val zip = File(dir.parentFile, "$sha256.zip")
    zip.parentFile.mkdirs()
    logger.lifecycle("qvac_flutter: downloading native binaries from $url")
    URI(url).toURL().openStream().use { input -> zip.outputStream().use { input.copyTo(it) } }
    val actual = MessageDigest.getInstance("SHA-256").digest(zip.readBytes())
        .joinToString("") { "%02x".format(it) }
    if (actual != sha256) {
        zip.delete()
        throw GradleException("qvac_flutter: $url has SHA-256 $actual, expected $sha256")
    }
    copy {
        from(zipTree(zip))
        into(dir)
    }
    zip.delete()
    return dir
}

android.sourceSets.getByName("main").jniLibs.srcDir(File(nativeDir, "src/main/jniLibs"))

dependencies {
    // BareKit's Java classes. The worker bundle itself ships in src/main/assets.
    implementation(files(File(nativeDir, "libs/bare-kit.jar")))
}
