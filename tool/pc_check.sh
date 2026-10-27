#!/usr/bin/env bash
# Проверка мыши и клавиатуры на ПК (сборка под Linux, виртуальный экран 1600×900).
# Сценарий — tool/pc_scenario.txt:
#   start [ПЕРЕМЕННАЯ=значение …]   — (пере)запустить программу
#   wait 3                          — подождать секунды
#   move X Y                        — плавно провести мышь в точку (как рука)
#   click X Y                       — щёлкнуть левой кнопкой
#   key Escape [N]                  — клавиша (имя для xdotool)
#   shot имя                        — снимок экрана
set -u
APP=build/linux/x64/release/bundle/deep_cinema
SCEN=${1:-tool/pc_scenario.txt}
mkdir -p shots
n=0; pid=
cx=1599; cy=899
start() {
  [ -n "$pid" ] && { kill $pid 2>/dev/null; sleep 1; kill -9 $pid 2>/dev/null; }
  xdotool mousemove 1599 899; cx=1599; cy=899
  env "$@" $APP >> shots/app.log 2>&1 &
  pid=$!
}
move() { # плавно, шагами — чтобы программа видела настоящее движение мыши
  local tx=$1 ty=$2 i
  for i in $(seq 1 12); do
    xdotool mousemove $(( cx + (tx - cx) * i / 12 )) $(( cy + (ty - cy) * i / 12 ))
    sleep 0.03
  done
  cx=$tx; cy=$ty
}
exec 3< "$SCEN"
while IFS= read -r -u 3 line || [ -n "$line" ]; do
  set -- $line
  [ $# -eq 0 ] && continue
  case "$1" in
    \#*) ;;
    start) shift; start "$@" ;;
    wait) sleep "$2" ;;
    move) move "$2" "$3"; sleep 0.6 ;;
    click) move "$2" "$3"; xdotool click 1; sleep 1 ;;
    key) c=${3:-1}; for _ in $(seq "$c"); do xdotool key "$2"; sleep 0.5; done; sleep 0.8 ;;
    shot) n=$((n+1)); import -window root "$(printf 'shots/%02d-%s.png' $n "$2")" ;;
  esac
done
[ -n "$pid" ] && kill $pid 2>/dev/null
true
