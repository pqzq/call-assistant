allprojects {
    repositories {
        // 国内镜像优先，避免 google() 直连超时
        maven { url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/") }
        maven { url = uri("https://repo.huaweicloud.com/repository/maven/") }
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
    // 插件模块（pub 缓存在 C:）与本项目 build 目录（D:）不在同一磁盘根，
    // 而 AGP 在 unitTests.includeAndroidResources=true 时会创建 GenerateTestConfig 任务，
    // 它用相对路径把模块目录连到 build 目录，跨盘会抛
    // "this and base files have different roots" 并让配置阶段直接失败。
    // Flutter 应用构建不会跑插件的单元测试，这里统一关掉。
    afterEvaluate {
        plugins.withId("com.android.library") {
            extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
                testOptions.unitTests.isIncludeAndroidResources = false
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
