#!/usr/bin/env bash
# Заливка конфигов на сервер и запуск контейнеров.
#
#   ./sync.sh              # без аргумента: залить файлы и поднять
#   ./sync.sh code         # только залить файлы, ничего не трогать
#   ./sync.sh conf         # отправить .env и config.yaml (только по явной команде)
#   ./sync.sh login        # OAuth-логин гугл-аккаунта на сервере через ssh-туннель
#   ./sync.sh up           # поднять то, что уже лежит на сервере
#   ./sync.sh update       # подтянуть свежий образ CLIProxyAPI и перезапустить
#   ./sync.sh restart      # перезапустить контейнеры
#   ./sync.sh logs         # хвост логов, Ctrl-C для выхода
#
# .env и config.yaml сами по себе не едут: в них ключи, и на сервере они могут отличаться.
# Команда conf перезаписывает серверные файлы целиком — зови её осознанно.
# Сертификаты не едут никогда, они лежат на сервере в каталоге из CERT_DIR.
# auths/ с OAuth-токенами тоже остаётся на сервере: увезёшь копию — два инстанса
# начнут обновлять один и тот же refresh-токен и вышибут друг друга.
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

# порт, на который Google возвращает OAuth-колбэк для Antigravity
CALLBACK_PORT=51121

# без --info=progress2: на macOS rsync — это openrsync, он такого флага не знает
RS=(rsync -avz)

remote() { ssh "$HOST" "cd $RPATH && docker compose $*"; }

code_push() {
  ssh "$HOST" "mkdir -p $RPATH"
  "${RS[@]}" docker-compose.yml .env.example config.example.yaml README.md sync.sh "$REMOTE/"
}

conf_push() {
  [ -f .env ] || { echo "локального .env нет" >&2; exit 1; }
  [ -f config.yaml ] || { echo "локального config.yaml нет" >&2; exit 1; }
  "${RS[@]}" .env config.yaml "$REMOTE/"
}

# Логин идёт в контейнере на сервере, а браузер у тебя. Туннель прокидывает твой
# localhost:51121 на серверный, поэтому ссылка из вывода открывается как есть.
login() {
  echo "открой напечатанную ссылку в своём браузере, колбэк придёт по туннелю"
  ssh -t -L "$CALLBACK_PORT:localhost:$CALLBACK_PORT" "$HOST" \
    "cd $RPATH && docker compose run --rm -p 127.0.0.1:$CALLBACK_PORT:$CALLBACK_PORT \
     cli-proxy-api ./CLIProxyAPI -antigravity-login -no-browser"
}

up() { remote up -d; remote ps; }

case "${1:-all}" in
  code) code_push ;;
  conf) conf_push ;;
  login) login ;;
  up) up ;;
  update) remote pull; up ;;
  restart) remote restart; remote ps ;;
  logs) remote logs -f --tail=100 ;;
  all) code_push; up ;;
  *) echo "usage: $0 [all|code|conf|login|up|update|restart|logs]" >&2; exit 2 ;;
esac
