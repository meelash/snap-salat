# The ML Kit text-recognition plugin can load Chinese, Devanagari, Japanese
# and Korean models, but Snap Salat only bundles Latin script. Tell R8 those
# optional classes are absent on purpose.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
