"""Донастройка платформенных папок после `flutter create` в облачной сборке.

- Android: название, интернет, режим Android TV (leanback), баннер и иконка.
- Windows: заголовок окна и иконка.
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, 'tool', 'assets')


def patch_android():
    manifest = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'AndroidManifest.xml')
    if not os.path.exists(manifest):
        print('android: manifest not found, skip')
        return
    with open(manifest, encoding='utf-8') as f:
        xml = f.read()

    xml = re.sub(r'android:label="[^"]*"', 'android:label="Deep Cinema"', xml, count=1)

    extra = (
        '    <uses-permission android:name="android.permission.INTERNET"/>\n'
        '    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>\n'
        '    <uses-permission android:name="android.permission.RECORD_AUDIO"/>\n'
        '    <uses-feature android:name="android.hardware.microphone" android:required="false"/>\n'
        '    <uses-feature android:name="android.software.leanback" android:required="false"/>\n'
        '    <uses-feature android:name="android.hardware.touchscreen" android:required="false"/>\n'
    )
    if 'android.software.leanback' not in xml:
        xml = re.sub(r'(<manifest[^>]*>\s*)', lambda m: m.group(1) + extra, xml, count=1)

    if 'android:banner' not in xml:
        xml = xml.replace('<application', '<application\n        android:banner="@drawable/banner"\n        android:usesCleartextTraffic="true"', 1)

    # Обновления: установка скачанного APK через FileProvider.
    if 'androidx.core.content.FileProvider' not in xml:
        provider = (
            '\n        <provider\n'
            '            android:name="androidx.core.content.FileProvider"\n'
            '            android:authorities="${applicationId}.files"\n'
            '            android:exported="false"\n'
            '            android:grantUriPermissions="true">\n'
            '            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/file_paths"/>\n'
            '        </provider>\n    '
        )
        xml = xml.replace('</application>', provider + '</application>', 1)

    # Слабые ТВ: старый движок отрисовки (Skia) на них заметно плавнее нового (Impeller).
    if 'EnableImpeller' not in xml:
        xml = xml.replace('</application>', '    <meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false"/>\n    </application>', 1)

    if 'LEANBACK_LAUNCHER' not in xml:
        xml = xml.replace(
            '<category android:name="android.intent.category.LAUNCHER"/>',
            '<category android:name="android.intent.category.LAUNCHER"/>\n'
            '                <category android:name="android.intent.category.LEANBACK_LAUNCHER"/>',
            1,
        )

    view_https = ('<intent><action android:name="android.intent.action.VIEW"/>'
                  '<data android:scheme="https"/></intent>')
    if view_https not in xml:
        if '<queries>' in xml:
            xml = xml.replace('<queries>', '<queries>\n        ' + view_https, 1)
        else:
            xml = xml.replace('</manifest>', '    <queries>' + view_https + '</queries>\n</manifest>', 1)

    with open(manifest, 'w', encoding='utf-8') as f:
        f.write(xml)

    res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
    os.makedirs(os.path.join(res, 'drawable'), exist_ok=True)
    os.makedirs(os.path.join(res, 'xml'), exist_ok=True)
    with open(os.path.join(res, 'xml', 'file_paths.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<paths>\n    <cache-path name="cache" path="."/>\n</paths>\n')
    # Тёмный фон при запуске (без белой вспышки до заставки приложения).
    dark = ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <item><color android:color="#FF0B0B0E"/></item>\n'
            '</layer-list>\n')
    for d in ('drawable', 'drawable-v21'):
        os.makedirs(os.path.join(res, d), exist_ok=True)
        with open(os.path.join(res, d, 'launch_background.xml'), 'w', encoding='utf-8') as f:
            f.write(dark)
    for d in ('values', 'values-night'):
        st = os.path.join(res, d, 'styles.xml')
        if os.path.exists(st):
            with open(st, encoding='utf-8') as f:
                x = f.read()
            x = x.replace('Theme.Light.NoTitleBar', 'Theme.Black.NoTitleBar')
            x = re.sub(r'<item name="android:windowBackground">[^<]*</item>', '<item name="android:windowBackground">@drawable/launch_background</item>', x)
            with open(st, 'w', encoding='utf-8') as f:
                f.write(x)
    shutil.copy(os.path.join(ASSETS, 'banner.png'), os.path.join(res, 'drawable', 'banner.png'))
    for d in ('mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'):
        dst = os.path.join(res, f'mipmap-{d}')
        os.makedirs(dst, exist_ok=True)
        shutil.copy(os.path.join(ASSETS, f'mipmap-{d}', 'ic_launcher.png'), os.path.join(dst, 'ic_launcher.png'))
    patch_gradle()
    patch_main_activity()
    print('android: patched')


def patch_gradle():
    # Встроенный торрент-движок лежит в jniLibs как исполняемый файл: его нельзя сжимать и «обрезать».
    app = os.path.join(ROOT, 'android', 'app')
    kts = os.path.join(app, 'build.gradle.kts')
    groovy = os.path.join(app, 'build.gradle')
    if os.path.exists(kts):
        path, block = kts, ('\n    packaging {\n        jniLibs {\n            useLegacyPackaging = true\n'
                            '            keepDebugSymbols += "**/libtorrserver.so"\n        }\n    }\n')
    elif os.path.exists(groovy):
        path, block = groovy, ('\n    packagingOptions {\n        jniLibs {\n            useLegacyPackaging true\n'
                               '            keepDebugSymbols += "**/libtorrserver.so"\n        }\n    }\n')
    else:
        print('android: gradle file not found')
        return
    with open(path, encoding='utf-8') as f:
        src = f.read()
    if 'libtorrserver' not in src:
        src = re.sub(r'(\nandroid\s*\{)', lambda m: m.group(1) + block, src, count=1)
    # Постоянный ключ подписи (tool/assets/signing.keystore): иначе каждая сборка
    # подписывалась случайным ключом, и Android не ставил обновление поверх.
    ks = os.path.join(ROOT, 'tool', 'assets', 'signing.keystore').replace('\\', '/')
    if 'dcRelease' not in src:
        if path.endswith('.kts'):
            cfg = ('\n    signingConfigs {\n        create("dcRelease") {\n'
                   f'            storeFile = file("{ks}")\n'
                   '            storePassword = "android"\n            keyAlias = "androiddebugkey"\n            keyPassword = "android"\n'
                   '        }\n    }\n')
        else:
            cfg = ('\n    signingConfigs {\n        dcRelease {\n'
                   f"            storeFile file('{ks}')\n"
                   "            storePassword 'android'\n            keyAlias 'androiddebugkey'\n            keyPassword 'android'\n"
                   '        }\n    }\n')
        src = re.sub(r'(\n\s*buildTypes\s*\{)', lambda m: cfg + m.group(1), src, count=1)
        src = re.sub(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)', 'signingConfig = signingConfigs.getByName("dcRelease")', src)
        src = re.sub(r"signingConfig\s+signingConfigs\.debug", 'signingConfig signingConfigs.dcRelease', src)
        if 'getByName("dcRelease")' not in src and 'signingConfigs.dcRelease' not in src:
            print('android: WARNING release signing not replaced')
    if 'androidx.core:core' not in src:
        dep = '\ndependencies {\n    implementation("androidx.core:core:1.13.1")\n}\n' if path.endswith('.kts') else "\ndependencies {\n    implementation 'androidx.core:core:1.13.1'\n}\n"
        src += dep
    with open(path, 'w', encoding='utf-8') as f:
        f.write(src)


MAIN_ACTIVITY = '''package {pkg}

import android.content.Intent
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {{
    // Звуки интерфейса: SoundPool — лёгкий и мгновенный (видеоплеер для щелчков на ТВ тормозил).
    private var pool: android.media.SoundPool? = null
    private val sounds = HashMap<String, Int>()
    private var voiceResult: MethodChannel.Result? = null
    private var channel: MethodChannel? = null
    private var recognizer: android.speech.SpeechRecognizer? = null

    private fun voiceEvent(type: String, value: String = "") {{
        runOnUiThread {{ channel?.invokeMethod("voiceEvent", mapOf("type" to type, "value" to value)) }}
    }}

    // Голосовой ввод прямо в приложении: своё окно записи, без системного диалога.
    private fun startVoice() {{
        runOnUiThread {{
            if (!android.speech.SpeechRecognizer.isRecognitionAvailable(this)) {{
                voiceEvent("error", "unavailable")
                return@runOnUiThread
            }}
            recognizer?.destroy()
            val r = android.speech.SpeechRecognizer.createSpeechRecognizer(this)
            recognizer = r
            r.setRecognitionListener(object : android.speech.RecognitionListener {{
                override fun onReadyForSpeech(params: android.os.Bundle?) {{ voiceEvent("ready") }}
                override fun onBeginningOfSpeech() {{ voiceEvent("speech") }}
                override fun onRmsChanged(rmsdB: Float) {{}}
                override fun onBufferReceived(buffer: ByteArray?) {{}}
                override fun onEndOfSpeech() {{ voiceEvent("end") }}
                override fun onError(error: Int) {{ voiceEvent("error", error.toString()) }}
                override fun onResults(results: android.os.Bundle?) {{
                    val t = results?.getStringArrayList(android.speech.SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
                    voiceEvent("result", t)
                }}
                override fun onPartialResults(partialResults: android.os.Bundle?) {{
                    val t = partialResults?.getStringArrayList(android.speech.SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
                    if (t.isNotEmpty()) voiceEvent("partial", t)
                }}
                override fun onEvent(eventType: Int, params: android.os.Bundle?) {{}}
            }})
            val i = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            i.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL, android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            i.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE, "ru-RU")
            i.putExtra(android.speech.RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            r.startListening(i)
        }}
    }}

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {{
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 7302) {{
            if (grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED) startVoice()
            else voiceEvent("error", "permission")
        }}
    }}

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {{
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 7301) {{
            val r = voiceResult
            voiceResult = null
            val text = data?.getStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
            r?.success(if (resultCode == RESULT_OK) text else null)
        }}
    }}

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "deepcinema/native")
        channel = ch
        ch.setMethodCallHandler {{ call, result ->
            when (call.method) {{
                "nativeLibDir" -> result.success(applicationInfo.nativeLibraryDir)
                "sfxLoad" -> {{
                    try {{
                        val p = pool ?: android.media.SoundPool.Builder().setMaxStreams(3).setAudioAttributes(
                            android.media.AudioAttributes.Builder()
                                .setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build()
                        ).build().also {{ pool = it }}
                        val loader = io.flutter.FlutterInjector.instance().flutterLoader()
                        for (n in call.argument<List<String>>("names") ?: emptyList()) {{
                            if (sounds.containsKey(n)) continue
                            val fd = assets.openFd(loader.getLookupKeyForAsset("assets/sfx/$n.wav"))
                            sounds[n] = p.load(fd, 1)
                            fd.close()
                        }}
                        result.success(true)
                    }} catch (e: Exception) {{
                        result.success(false)
                    }}
                }}
                "voice" -> {{
                    // Голосовой поиск: системное окно распознавания речи (Google на Android TV).
                    try {{
                        val intent = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                        intent.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL, android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                        intent.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE, "ru-RU")
                        intent.putExtra(android.speech.RecognizerIntent.EXTRA_PROMPT, "Скажите название фильма или сериала")
                        voiceResult?.success(null)
                        voiceResult = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, 7301)
                    }} catch (e: Exception) {{
                        voiceResult = null
                        result.error("none", e.message, null)
                    }}
                }}
                "voiceStart" -> {{
                    if (Build.VERSION.SDK_INT >= 23 && checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {{
                        requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 7302)
                        result.success("permission")
                    }} else {{
                        startVoice()
                        result.success("ok")
                    }}
                }}
                "voiceStop" -> {{
                    runOnUiThread {{ recognizer?.stopListening() }}
                    result.success(null)
                }}
                "voiceCancel" -> {{
                    runOnUiThread {{ recognizer?.cancel() }}
                    result.success(null)
                }}
                "sfx" -> {{
                    val id = sounds[call.argument<String>("name") ?: ""]
                    if (id != null) pool?.play(id, 0.85f, 0.85f, 1, 0, 1f)
                    result.success(null)
                }}
                "filesDir" -> result.success(filesDir.absolutePath)
                "installApk" -> {{
                    try {{
                        val file = File(call.argument<String>("path")!!)
                        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                        val intent = Intent(Intent.ACTION_VIEW)
                        intent.setDataAndType(uri, "application/vnd.android.package-archive")
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(null)
                    }} catch (e: Exception) {{
                        result.error("install", e.message, null)
                    }}
                }}
                "displayInfo" -> {{
                    try {{
                        @Suppress("DEPRECATION")
                        val d = if (Build.VERSION.SDK_INT >= 30) display else windowManager.defaultDisplay
                        if (d == null || Build.VERSION.SDK_INT < 23) result.success("")
                        else {{
                            val cur = d.mode
                            val rates = d.supportedModes
                                .filter {{ it.physicalWidth == cur.physicalWidth && it.physicalHeight == cur.physicalHeight }}
                                .map {{ String.format("%.2f", it.refreshRate) }}.distinct().joinToString(", ")
                            result.success(String.format("%.2f Гц (%dx%d), умеет: %s", cur.refreshRate, cur.physicalWidth, cur.physicalHeight, rates))
                        }}
                    }} catch (e: Exception) {{
                        result.success("")
                    }}
                }}
                "matchFrameRate" -> {{
                    // Частота экрана под фильм: режим с той же картинкой и частотой, кратной кадрам видео.
                    try {{
                        val fps = (call.argument<Double>("fps") ?: 0.0).toFloat()
                        @Suppress("DEPRECATION")
                        val display = if (Build.VERSION.SDK_INT >= 30) display else windowManager.defaultDisplay
                        var best = 0
                        if (display != null && fps > 1f && Build.VERSION.SDK_INT >= 23) {{
                            val cur = display.mode
                            var bestErr = Float.MAX_VALUE
                            for (m in display.supportedModes) {{
                                if (m.physicalWidth != cur.physicalWidth || m.physicalHeight != cur.physicalHeight) continue
                                val mult = Math.round(m.refreshRate / fps)
                                if (mult < 1) continue
                                val err = Math.abs(m.refreshRate - fps * mult)
                                if (err > 0.06f * mult) continue
                                val score = err * 10 + mult
                                if (score < bestErr) {{ bestErr = score; best = m.modeId }}
                            }}
                            if (best == cur.modeId) best = 0
                        }}
                        val id = best
                        if (Build.VERSION.SDK_INT >= 23) runOnUiThread {{
                            val lp = window.attributes
                            if (lp.preferredDisplayModeId != id) {{
                                lp.preferredDisplayModeId = id
                                window.attributes = lp
                            }}
                        }}
                        result.success(id)
                    }} catch (e: Exception) {{
                        result.error("fps", e.message, null)
                    }}
                }}
                else -> result.notImplemented()
            }}
        }}
    }}
}}
'''


def patch_main_activity():
    src_root = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'kotlin')
    for dirpath, _, files in os.walk(src_root):
        if 'MainActivity.kt' in files:
            path = os.path.join(dirpath, 'MainActivity.kt')
            with open(path, encoding='utf-8') as f:
                m = re.search(r'^package\s+([\w.]+)', f.read(), re.M)
            pkg = m.group(1) if m else 'app.deepcinema.deep_cinema'
            with open(path, 'w', encoding='utf-8') as f:
                f.write(MAIN_ACTIVITY.format(pkg=pkg))
            print('android: MainActivity patched')
            return
    print('android: MainActivity not found')


def patch_windows():
    main_cpp = os.path.join(ROOT, 'windows', 'runner', 'main.cpp')
    if not os.path.exists(main_cpp):
        print('windows: main.cpp not found, skip')
        return
    with open(main_cpp, encoding='utf-8') as f:
        src = f.read()
    src = re.sub(r'window\.Create\(L"[^"]*"', 'window.Create(L"Deep Cinema"', src)
    src = re.sub(r'Win32Window::Size size\(\d+, \d+\)', 'Win32Window::Size size(1600, 900)', src)
    with open(main_cpp, 'w', encoding='utf-8') as f:
        f.write(src)
    ico = os.path.join(ROOT, 'windows', 'runner', 'resources', 'app_icon.ico')
    if os.path.exists(os.path.dirname(ico)):
        shutil.copy(os.path.join(ASSETS, 'app_icon.ico'), ico)
    print('windows: patched')


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if target in ('android', 'all'):
        patch_android()
    if target in ('windows', 'all'):
        patch_windows()
