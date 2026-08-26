allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val media3Version = "1.10.1"

// Build into the project's own build/ dir. (Was hard-coded to
// C:/Voltix-build/moonfin-client/build, which put outputs where Flutter and
// the build script couldn't find them.)
rootProject.layout.buildDirectory.set(rootProject.file("../build"))

subprojects {
    // Anchor to the ROOT project dir (android/), not each subproject's dir, so
    // every module's output lands under merge/build/<module> (not android/build).
    project.layout.buildDirectory.set(rootProject.file("../build/${project.name}"))
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    configurations.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "androidx.media3") {
                useVersion(media3Version)
            }
        }
    }
}

// Release builds don't need Android Lint, and lintVitalAnalyzeRelease is a known
// flake on Windows: it wipes/reuses a lint cache whose jars are often still held
// by another process ("The process cannot access the file because it is being
// used by another process"), failing the whole build. Turn it off for every
// module (app + Flutter plugins).
subprojects {
    tasks.configureEach {
        if (name.startsWith("lintVital") || name.startsWith("lintAnalyze")) {
            enabled = false
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
