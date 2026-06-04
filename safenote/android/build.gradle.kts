allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")

    // 플러그인 서브프로젝트들이 Java 8(source/target value 8)로 컴파일되며 내는
    // "obsolete options" 경고만 억제한다. 동작/산출물(APK) 변화 없이 빌드 로그 소음만 제거.
    // (앱 모듈은 이미 Java 11 — app/build.gradle.kts compileOptions 참조)
    tasks.withType<JavaCompile>().configureEach {
        options.compilerArgs.add("-Xlint:-options")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
