// Root build file. Plugin versions are pinned here (no version catalog) so the
// set is known-compatible: Kotlin 2.0.21 + Compose compiler 2.0.21 + AGP 8.7.2.
plugins {
    id("com.android.application") version "8.7.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.21" apply false
}
