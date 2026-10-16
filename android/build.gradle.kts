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
        consumerProguardFiles("consumer-rules.pro")
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
    // In the Gradle home, so flutter clean doesn't throw away 60 MB.
    val dir = File(gradle.gradleUserHomeDir, "caches/qvac_flutter/$sha256")
    if (File(dir, "libs/bare-kit.jar").isFile) return dir
    val url = (findProperty("qvacBinariesUrl") as String?) ?: release.getValue("url")
    if (gradle.startParameter.isOffline) {
        throw GradleException("qvac_flutter: native binaries are not cached yet. Build once online to fetch $url")
    }
    val zip = File(dir.parentFile, "$sha256.zip.part")
    zip.parentFile.mkdirs()
    logger.lifecycle("qvac_flutter: downloading native binaries from $url")
    val connection = URI(url).toURL().openConnection().apply {
        connectTimeout = 30_000
        readTimeout = 60_000
    }
    connection.getInputStream().use { input -> zip.outputStream().use { input.copyTo(it) } }
    val actual = MessageDigest.getInstance("SHA-256").digest(zip.readBytes())
        .joinToString("") { "%02x".format(it) }
    if (actual != sha256) {
        zip.delete()
        throw GradleException("qvac_flutter: $url has SHA-256 $actual, expected $sha256")
    }
    // Unpack next to it and rename, so a stopped build never leaves half a folder.
    val tmp = File(dir.parentFile, "$sha256.tmp")
    tmp.deleteRecursively()
    copy {
        from(zipTree(zip))
        into(tmp)
    }
    zip.delete()
    dir.deleteRecursively()
    if (!tmp.renameTo(dir)) throw GradleException("qvac_flutter: could not move $tmp to $dir")
    return dir
}

android.sourceSets.getByName("main").jniLibs.srcDir(File(nativeDir, "src/main/jniLibs"))

dependencies {
    // BareKit's Java classes. The worker bundle itself ships in src/main/assets.
    implementation(files(File(nativeDir, "libs/bare-kit.jar")))
}
