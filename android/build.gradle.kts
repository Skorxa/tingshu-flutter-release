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
}

// 修复 "Inconsistent JVM-target compatibility":
// 各插件 Java target 不一(老插件 11、新插件 17),且评估后已锁死无法更改;
// 故让每个模块的 Kotlin jvmTarget 去匹配它自己的 Java targetCompatibility。
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        val javaTarget = project.tasks
            .withType(JavaCompile::class.java)
            .map { it.targetCompatibility }
            .firstOrNull() ?: "17"
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(javaTarget))
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
