#!/usr/bin/env bash
# Заливка конфигов на сервер и запуск контейнеров.
#
#   ./sync.sh              # без аргумента: залить файлы и поднять
#   ./sync.sh code         # только залить файлы, ничего не трогать
#   ./sync.sh up           # поднять то, что уже лежит на сервере
#   ./sync.sh update       # подтянуть свежий образ gemini-balance и перезапустить
#   ./sync.sh restart      # перезапустить контейнеры
#   ./sync.sh logs         # хвост логов, Ctrl-C для выхода
#   ./sync.sh env          # отправить локальный .env на сервер (только по явной команде)
#
# .env сам по себе не едет: на сервере свои ключи и свой домен. Команда env
# перезаписывает серверный файл целиком — зови её осознанно.
# Сертификаты не едут никогда, они лежат на сервере в каталоге из CERT_DIR.
# База в data/ тоже остаётся на сервере: там ключи, логи и правки из веб-морды.
#
# GPROXY_REMOTE в .env — корень проекта на сервере, вида host:~/gemini-proxy-docker/
set -euo pipefail
cd "$(dirname "$0")"

# .env читаем строкой, а не `source`: в присваивании bash раскрыл бы `~` после двоеточия
# по локальному $HOME, и путь на сервере превратился бы в /Users/... — rsync ищет его у себя.
# return 0 при отсутствии .env обязателен: иначе set -e убьёт скрипт на присваивании ниже,
# и вместо подсказки про GPROXY_REMOTE получится молчаливый выход
env_get() { [ -f .env ] || return 0; sed -n "s/^$1=//p" .env | tail -1 | tr -d "\"'"; }
REMOTE="${GPROXY_REMOTE:-$(env_get GPROXY_REMOTE)}"
REMOTE="${REMOTE:?укажи GPROXY_REMOTE=host:~/gemini-proxy-docker/ в .env}"
REMOTE="${REMOTE%/}"
HOST="${REMOTE%%:*}"
RPATH="${REMOTE#*:}"

# без --info=progress2: на macOS rsync — это openrsync, он такого флага не знает
RS=(rsync -avz)

remote() { ssh "$HOST" "cd $RPATH && docker compose $*"; }

code_push() {
  ssh "$HOST" "mkdir -p $RPATH"
  "${RS[@]}" docker-compose.yml Caddyfile .env.example README.md sync.sh "$REMOTE/"
}

# .env отдельной командой: он с секретами и на сервере может отличаться от локального
env_push() {
  [ -f .env ] || { echo "локального .env нет" >&2; exit 1; }
  "${RS[@]}" .env "$REMOTE/.env"
}

up() { remote up -d; remote ps; }

case "${1:-all}" in
  code) code_push ;;
  env) env_push ;;
  up) up ;;
  update) remote pull; up ;;
  restart) remote restart; remote ps ;;
  logs) remote logs -f --tail=100 ;;
  all) code_push; up ;;
  *) echo "usage: $0 [all|code|env|up|update|restart|logs]" >&2; exit 2 ;;
esac
