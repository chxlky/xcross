plugins { kotlin("multiplatform") }
repositories { mavenCentral() }

kotlin {
    iosArm64 {
        binaries.framework {
            baseName = "ComposeApp"
            isStatic = true
        }
        compilations.getByName("main").cinterops.create("probe") {
            definitionFile.set(project.file("src/nativeInterop/cinterop/probe.def"))
            includeDirs(project.file("src/nativeInterop/cinterop"))
        }
    }
}
