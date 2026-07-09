# kotlinx-serialization (release minify is off, but keep these in case it's enabled later).
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**

# Keep serializers generated for @Serializable classes.
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.attobot.dashboard.**$$serializer { *; }
-keepclassmembers class com.attobot.dashboard.** {
    *** Companion;
}
-keepclasseswithmembers class com.attobot.dashboard.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Retrofit
-keepattributes Signature, Exceptions
-keep class retrofit2.** { *; }
-keepclasseswithmembers class * {
    @retrofit2.http.* <methods>;
}
