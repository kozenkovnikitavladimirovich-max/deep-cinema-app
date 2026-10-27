#!/usr/bin/env bash
# Проверка управления пультом на эмуляторе Android (экран как у ТВ: 1920×1080, масштаб 2×).
# Запускается из .github/workflows/tv-check.yml. Сценарий — tool/tv_scenario.txt:
#   key DPAD_DOWN [N]   — нажать кнопку пульта (N раз, по умолчанию 1)
#   wait 3              — подождать секунды
#   shot имя            — снимок экрана в shots/имя.png
#   start               — (пере)запустить программу
#   text строка         — набрать текст (системной клавиатурой)
set -u
APK=$1
SCEN=${2:-tool/tv_scenario.txt}
PKG=app.deepcinema.deep_cinema
mkdir -p shots
adb wait-for-device
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell wm size 1920x1080
adb shell wm density 320
adb install -r -g "$APK" > shots/install.log 2>&1 || { cat shots/install.log; exit 1; }
n=0
start() {
  adb shell am force-stop $PKG
  adb logcat -c
  adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
}
exec 3< "$SCEN"
while IFS= read -r -u 3 line || [ -n "$line" ]; do
  set -- $line
  [ $# -eq 0 ] && continue
  case "$1" in
    \#*) ;;
    start) start ;;
    wait) sleep "$2" ;;
    key) c=${3:-1}; for _ in $(seq "$c"); do adb shell input keyevent "KEYCODE_$2" < /dev/null; sleep 0.7; done; sleep 1 ;;
    text) shift; adb shell input text "$(echo "$*" | sed 's/ /%s/g')"; sleep 1 ;;
    shot) n=$((n+1)); f=$(printf 'shots/%02d-%s.png' $n "$2"); adb exec-out screencap -p > "$f"; echo "снят $f" ;;
  esac
done
adb logcat -d -s flutter:V > shots/flutter.log 2>&1 || true
