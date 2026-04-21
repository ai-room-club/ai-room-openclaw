#!/usr/bin/env bash
#
# configure-openclaw.sh — конфигурация OpenClaw на VPS под канон
# AI Room Club: Codex OAuth + Telegram channel + loopback gateway + systemd user daemon.
#
# Запускается на VPS от root (или через sudo). Идемпотентный: повторный
# запуск не сломает то, что уже настроено.
#
# Что делает (не-интерактивно):
#   1. Запускает `openclaw doctor --fix` — создаёт ~/.openclaw/agents/.../,
#      подтягивает недостающие runtime deps.
#   2. Прописывает gateway config: mode=local (loopback), auth.enabled=true,
#      auth.token=<random-hex-32> (генерируется на месте).
#   3. Прописывает Telegram channel config: enabled, botToken, dmPolicy=pairing,
#      опционально allowFrom=[<user_id>].
#   4. Отключает Discord канал (канон — Telegram, discord-opus не нужен).
#   5. Отключает memorySearch (Codex OAuth не даёт embeddings; без API-ключа
#      эта фича всё равно не работает).
#   6. `loginctl enable-linger openclaw` — user systemd сервис живёт после logout.
#   7. Создаёт systemd user unit ~/.config/systemd/user/openclaw-gateway.service
#      вручную (не через `openclaw onboard --install-daemon`, который требует
#      TTY и имеет баги на headless VPS).
#   8. Запускает сервис (`systemctl --user enable --now openclaw-gateway`).
#   9. Сохраняет gateway auth token в ~/openclaw-gateway-token.txt (chmod 600).
#  10. Финальный `openclaw doctor` — ожидаем что `OAuth dir not present`
#      останется (это нормально до шага OAuth, который делает пользователь сам).
#
# Что пользователь делает руками ПОСЛЕ скрипта (эти шаги требуют TTY/браузер/Telegram):
#   a. OAuth Codex: `ssh openclaw@<IP>` → `openclaw models auth login --provider openai-codex`
#      → открыть URL в браузере (нужен VPN в РФ, auth.openai.com блокируется) →
#      завершить ChatGPT OAuth → paste redirect code обратно в SSH-сессию.
#   b. Pairing Telegram: написать DM своему боту → `openclaw logs --follow`
#      в другом SSH → взять pairing code → `openclaw pairing approve telegram <CODE>`.
#
# Флаги:
#   --username <name>              non-root пользователь (default: openclaw)
#   --telegram-token <TOKEN>       bot token от @BotFather (обязательный, если не --no-telegram)
#   --telegram-allow-user-id <ID>  numeric Telegram user ID для allowFrom (optional, может повторяться)
#   --no-telegram                  пропустить Telegram setup (настроится позже)
#   --gateway-mode <local|remote>  default: local
#   --gateway-port <port>          default: 18789
#   --skip-doctor-fix              не запускать `doctor --fix`
#   --skip-daemon                  не устанавливать systemd user unit
#   --json                         вывод в JSON
#   --dry-run                      preview без изменений
#   --help
#
# Exit codes:
#   0 — успех (возможны warnings)
#   1 — критичная ошибка
#   2 — warnings но не блокер
#

set -eo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly GATEWAY_UNIT_NAME="openclaw-gateway.service"

# --- Defaults ---
USERNAME="openclaw"
TELEGRAM_TOKEN=""
TELEGRAM_ALLOW_IDS=""   # space-separated
NO_TELEGRAM=0
GATEWAY_MODE="local"
GATEWAY_PORT="18789"
SKIP_DOCTOR_FIX=0
SKIP_DAEMON=0
OUTPUT_JSON=0
DRY_RUN=0

# --- Flags parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --username)                   USERNAME="$2"; shift 2 ;;
    --telegram-token)             TELEGRAM_TOKEN="$2"; shift 2 ;;
    --telegram-allow-user-id)     TELEGRAM_ALLOW_IDS="${TELEGRAM_ALLOW_IDS} $2"; shift 2 ;;
    --no-telegram)                NO_TELEGRAM=1; shift ;;
    --gateway-mode)               GATEWAY_MODE="$2"; shift 2 ;;
    --gateway-port)               GATEWAY_PORT="$2"; shift 2 ;;
    --skip-doctor-fix)            SKIP_DOCTOR_FIX=1; shift ;;
    --skip-daemon)                SKIP_DAEMON=1; shift ;;
    --json)                       OUTPUT_JSON=1; shift ;;
    --dry-run)                    DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '3,60p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

QUIET=0
[ "$OUTPUT_JSON" -eq 1 ] && QUIET=1

# --- State ---
ERRORS_LIST=""
WARNINGS_LIST=""
ERRORS_COUNT=0
WARNINGS_COUNT=0
ACTIONS_LIST=""

GATEWAY_TOKEN=""
OPENCLAW_BIN=""
USER_UID=""
USER_HOME=""

# --- Logging ---
log() {
  [ "$QUIET" -eq 1 ] && return 0
  printf '%s\n' "$1" >&2
}

log_info() { log "[+] $1"; }
log_ok()   { log "[✓] $1"; }
log_warn() {
  log "[!] $1"
  WARNINGS_LIST="${WARNINGS_LIST}${1}"$'\n'
  WARNINGS_COUNT=$((WARNINGS_COUNT + 1))
}
log_error() {
  log "[✗] $1"
  ERRORS_LIST="${ERRORS_LIST}${1}"$'\n'
  ERRORS_COUNT=$((ERRORS_COUNT + 1))
}

# --- User-scoped exec helpers ---

run_as_user() {
  local cmd="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run, as $USERNAME) $cmd"
    return 0
  fi
  sudo -u "$USERNAME" -i bash -lc "$cmd"
}

capture_as_user() {
  local cmd="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    return 0
  fi
  sudo -u "$USERNAME" -i bash -lc "$cmd" 2>/dev/null || true
}

# Запуск systemctl --user от имени openclaw с правильным XDG_RUNTIME_DIR.
# После `loginctl enable-linger` user@<UID>.service активен и этого достаточно.
run_systemctl_user() {
  local cmd="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run, as $USERNAME, XDG_RUNTIME_DIR=/run/user/$USER_UID) systemctl --user $cmd"
    return 0
  fi
  sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/$USER_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
    systemctl --user $cmd
}

# --- Validators ---

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "Скрипт должен запускаться от root (или через sudo)."
    return 1
  fi
}

check_user_exists() {
  if ! id "$USERNAME" >/dev/null 2>&1; then
    log_error "Пользователь '$USERNAME' не существует. Сначала запусти install-openclaw.sh."
    return 1
  fi
  USER_UID="$(id -u "$USERNAME")"
  USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
  log_ok "Пользователь '$USERNAME' найден (UID=$USER_UID, HOME=$USER_HOME)"
}

check_openclaw_installed() {
  local version
  version="$(capture_as_user 'openclaw --version 2>/dev/null' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -z "$version" ]; then
    log_error "openclaw не найден в PATH пользователя '$USERNAME'. Запусти install-openclaw.sh."
    return 1
  fi

  OPENCLAW_BIN="$(capture_as_user 'command -v openclaw')"
  if [ -z "$OPENCLAW_BIN" ] && [ "$DRY_RUN" -eq 0 ]; then
    log_error "command -v openclaw не вернул путь — странно, но есть версия. Проверь PATH."
    return 1
  fi
  [ "$DRY_RUN" -eq 1 ] && OPENCLAW_BIN="/home/$USERNAME/.npm-global/bin/openclaw"

  log_ok "OpenClaw v${version} найден (${OPENCLAW_BIN})"
}

check_telegram_args() {
  if [ "$NO_TELEGRAM" -eq 1 ]; then
    log_info "Telegram setup пропущен (--no-telegram)"
    return 0
  fi
  if [ -z "$TELEGRAM_TOKEN" ]; then
    log_error "Не передан --telegram-token. Создай бота в @BotFather, скопируй токен и перезапусти:"
    log_error "  sudo bash configure-openclaw.sh --telegram-token <TOKEN>"
    log_error "или пропусти Telegram сейчас через --no-telegram (настроишь позже)."
    return 1
  fi
  # Формат BotFather: "<digits>:<alphanum>"
  if ! echo "$TELEGRAM_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
    log_error "Формат --telegram-token не похож на токен BotFather'а (ожидается '123456789:ABC-xyz')."
    return 1
  fi
}

check_gateway_mode_arg() {
  case "$GATEWAY_MODE" in
    local|remote) : ;;
    *)
      log_error "Некорректный --gateway-mode: '$GATEWAY_MODE'. Ожидается local или remote."
      return 1
      ;;
  esac
}

# --- Actions ---

action_doctor_fix() {
  if [ "$SKIP_DOCTOR_FIX" -eq 1 ]; then
    log_info "Пропускаю openclaw doctor --fix (--skip-doctor-fix)"
    return 0
  fi

  log_info "Запускаю openclaw doctor --fix (создание недостающих директорий, установка runtime deps)..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run, as $USERNAME) openclaw doctor --fix"
    return 0
  fi

  # --fix может долго ставить npm-пакеты (discord opus) — не глушим вывод.
  if ! run_as_user 'openclaw doctor --fix'; then
    log_warn "openclaw doctor --fix завершился с ошибкой. Продолжаем — часть state создаст сам gateway."
  else
    log_ok "openclaw doctor --fix выполнен"
  fi
}

action_generate_gateway_token() {
  if [ "$DRY_RUN" -eq 1 ]; then
    GATEWAY_TOKEN="<dry-run-token>"
    log "      (dry-run) GATEWAY_TOKEN = <random-hex-32>"
    return 0
  fi
  GATEWAY_TOKEN="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  if [ -z "$GATEWAY_TOKEN" ] || [ ${#GATEWAY_TOKEN} -lt 32 ]; then
    log_error "Не удалось сгенерировать gateway auth token (нет openssl и /dev/urandom?)."
    return 1
  fi
  log_ok "Gateway auth token сгенерирован (64 hex chars)"
}

# openclaw config set <key> <value>.
# Значения с точками и спец-символами — в одинарных кавычках.
config_set() {
  local key="$1"
  local value="$2"
  local mask="${3:-}"   # если "mask" — не печатаем значение в лог
  local display_val="$value"
  [ "$mask" = "mask" ] && display_val="****"

  log_info "  set $key=$display_val"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run, as $USERNAME) openclaw config set $key '$value'"
    return 0
  fi
  # Передаём через -i login shell, чтобы PATH и env пользователя подтянулись.
  # Значение в одинарных кавычках защищает от интерполяции на стороне sudo.
  if ! sudo -u "$USERNAME" -i bash -lc "openclaw config set $key '$value'" >/dev/null 2>&1; then
    log_error "openclaw config set $key упал. Проверь вручную: sudo -u $USERNAME -i openclaw config get $key"
    return 1
  fi
}

action_config_gateway() {
  log_info "Прописываю gateway config..."
  config_set "gateway.mode" "$GATEWAY_MODE"
  config_set "gateway.auth.enabled" "true"
  config_set "gateway.auth.token" "$GATEWAY_TOKEN" mask
  config_set "gateway.port" "$GATEWAY_PORT"
  log_ok "Gateway: mode=$GATEWAY_MODE, auth enabled, port=$GATEWAY_PORT"
}

action_config_telegram() {
  if [ "$NO_TELEGRAM" -eq 1 ]; then
    return 0
  fi

  log_info "Прописываю Telegram channel config..."
  config_set "channels.telegram.enabled" "true"
  config_set "channels.telegram.botToken" "$TELEGRAM_TOKEN" mask
  config_set "channels.telegram.dmPolicy" "pairing"

  # allowFrom: JSON-массив numeric IDs. Собираем из space-separated TELEGRAM_ALLOW_IDS.
  local allow_json="[]"
  if [ -n "${TELEGRAM_ALLOW_IDS// /}" ]; then
    # shellcheck disable=SC2001
    allow_json="[$(echo "$TELEGRAM_ALLOW_IDS" | sed 's/^ *//;s/ *$//' | awk '{
      for (i=1; i<=NF; i++) {
        if (i>1) printf ",";
        printf "\"%s\"", $i
      }
    }')]"
    config_set "channels.telegram.allowFrom" "$allow_json"
    log_ok "Telegram: enabled, dmPolicy=pairing, allowFrom=$allow_json"
  else
    log_ok "Telegram: enabled, dmPolicy=pairing (allowFrom не задан — пэйринг прокинется по первому DM)"
  fi
}

action_config_discord_off() {
  log_info "Отключаю Discord канал (канон — Telegram)..."
  config_set "channels.discord.enabled" "false"
  log_ok "Discord отключён"
}

action_config_memory_search_off() {
  log_info "Отключаю memorySearch (без embedding-ключа не работает — включишь когда добавишь API-ключ)..."
  config_set "agents.defaults.memorySearch.enabled" "false"
  log_ok "memorySearch отключён"
}

action_save_gateway_token_file() {
  local token_file="${USER_HOME}/openclaw-gateway-token.txt"
  log_info "Сохраняю gateway token в $token_file (chmod 600)..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) echo '<token>' > $token_file; chmod 600; chown $USERNAME"
    return 0
  fi

  umask 077
  printf '%s\n' "$GATEWAY_TOKEN" > "$token_file"
  chmod 600 "$token_file"
  chown "$USERNAME:$USERNAME" "$token_file"
  log_ok "Gateway token сохранён. Посмотреть: cat ~/openclaw-gateway-token.txt (под $USERNAME)"
}

action_enable_linger() {
  if [ "$SKIP_DAEMON" -eq 1 ]; then
    log_info "Пропускаю loginctl enable-linger (--skip-daemon)"
    return 0
  fi

  log_info "Включаю user-systemd linger для $USERNAME (сервис живёт после logout)..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) loginctl enable-linger $USERNAME"
    return 0
  fi

  # Идемпотентно: уже enabled → noop.
  if loginctl show-user "$USERNAME" 2>/dev/null | grep -q '^Linger=yes$'; then
    log_ok "Linger уже включён для $USERNAME"
  else
    loginctl enable-linger "$USERNAME"
    log_ok "Linger включён"
  fi

  # Убеждаемся что /run/user/<UID> существует и открыт для user.
  # loginctl enable-linger должен его создать, но на некоторых образах нужна явная проверка.
  local rt_dir="/run/user/$USER_UID"
  if [ ! -d "$rt_dir" ]; then
    log_warn "$rt_dir не существует сразу после enable-linger — создам вручную."
    mkdir -p "$rt_dir"
    chown "$USER_UID:$USER_UID" "$rt_dir"
    chmod 700 "$rt_dir"
  fi
}

action_install_systemd_unit() {
  if [ "$SKIP_DAEMON" -eq 1 ]; then
    log_info "Пропускаю установку systemd user unit (--skip-daemon)"
    return 0
  fi

  local unit_dir="${USER_HOME}/.config/systemd/user"
  local unit_path="${unit_dir}/${GATEWAY_UNIT_NAME}"

  log_info "Устанавливаю systemd user unit $unit_path..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) mkdir -p $unit_dir"
    log "      (dry-run) write $unit_path (ExecStart=$OPENCLAW_BIN gateway --port $GATEWAY_PORT)"
    return 0
  fi

  mkdir -p "$unit_dir"
  chown "$USERNAME:$USERNAME" "$unit_dir" "${USER_HOME}/.config" "${USER_HOME}/.config/systemd" 2>/dev/null || true

  # cat heredoc с abs путями — без expand переменных пользователя.
  cat > "$unit_path" <<UNIT
[Unit]
Description=OpenClaw Gateway (AI Room Club)
Documentation=https://docs.openclaw.ai
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${OPENCLAW_BIN} gateway --port ${GATEWAY_PORT}
Restart=always
RestartSec=5
Environment=PATH=${USER_HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
# Логи в journalctl --user-unit=${GATEWAY_UNIT_NAME}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
UNIT

  chown "$USERNAME:$USERNAME" "$unit_path"
  chmod 644 "$unit_path"
  log_ok "Unit-файл записан: $unit_path"
}

action_start_daemon() {
  if [ "$SKIP_DAEMON" -eq 1 ]; then
    return 0
  fi

  log_info "Запускаю systemd user daemon..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) systemctl --user daemon-reload"
    log "      (dry-run) systemctl --user enable --now $GATEWAY_UNIT_NAME"
    return 0
  fi

  # daemon-reload обязателен после создания нового unit-файла.
  if ! run_systemctl_user "daemon-reload"; then
    log_error "systemctl --user daemon-reload упал. Возможно, user-session не поднялась — попробуй: sudo machinectl shell $USERNAME@"
    return 1
  fi

  if ! run_systemctl_user "enable --now $GATEWAY_UNIT_NAME"; then
    log_error "systemctl --user enable --now $GATEWAY_UNIT_NAME упал."
    log_error "Диагностика: sudo -u $USERNAME XDG_RUNTIME_DIR=/run/user/$USER_UID systemctl --user status $GATEWAY_UNIT_NAME"
    return 1
  fi

  # Смотрим is-active — должен быть active.
  local state
  state="$(sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/$USER_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
    systemctl --user is-active "$GATEWAY_UNIT_NAME" 2>/dev/null || true)"
  if [ "$state" = "active" ]; then
    log_ok "Gateway daemon запущен (systemctl --user is-active → active)"
  else
    log_warn "Gateway daemon is-active вернул '$state' (ожидалось 'active'). Проверь логи: journalctl --user-unit=$GATEWAY_UNIT_NAME"
  fi
}

action_final_doctor() {
  log_info "Запускаю финальный openclaw doctor для проверки состояния..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) openclaw doctor"
    return 0
  fi

  local doctor_output
  doctor_output="$(capture_as_user 'openclaw doctor 2>&1')"

  # Тот же grep-подход, что в install-openclaw.sh (см. коммит 52ac4e3):
  # строки имеют вид "│  - CRITICAL: …" — рамка box-drawing, не ASCII-пробел.
  # Ищем стабильный substring "- CRITICAL:" / "- WARNING:". `--` отделяет
  # grep-флаги от pattern'а (pattern начинается с `-`).
  local crit warn
  crit=$(echo "$doctor_output" | grep -cE -- '- CRITICAL:' || true)
  warn=$(echo "$doctor_output" | grep -cE -- '- WARNING:' || true)

  # После configure ожидаемый остаточный critical — "OAuth dir not present"
  # (credentials/ создаются при первом `openclaw models auth login ...`,
  # который пользователь запускает сам интерактивно). Всё с pattern
  # "… not present" или "… missing" относим к ожидаемым.
  local expected
  expected=$(echo "$doctor_output" | grep -cE -- '- CRITICAL:.*(missing|not present)' || true)

  if [ "$crit" -eq 0 ]; then
    if [ "$warn" -gt 0 ]; then
      log_warn "openclaw doctor: $warn warning(s). Детали: sudo -u $USERNAME openclaw doctor"
    else
      log_ok "openclaw doctor: проблем не обнаружено"
    fi
  elif [ "$crit" -eq "$expected" ]; then
    log_info "openclaw doctor: $crit critical(s), все про отсутствующие auth-артефакты."
    log_info "  Ожидаемо до ручного шага 'openclaw models auth login --provider openai-codex'."
    log_info "  Детали: sudo -u $USERNAME openclaw doctor"
  else
    log_error "openclaw doctor нашёл $crit critical issue(s). Вывод:"
    log ""
    echo "$doctor_output" | while IFS= read -r line; do log "  $line"; done
  fi
}

# --- Summary ---

print_summary_human() {
  log ""
  log "================================================"
  local prefix=""
  [ "$DRY_RUN" -eq 1 ] && prefix="[DRY-RUN] "

  if [ "$ERRORS_COUNT" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "${prefix}ИТОГ: план корректен. Система НЕ менялась (dry-run)."
    else
      log "${prefix}ИТОГ: OpenClaw сконфигурирован. ✓"
      log ""
      log "  Gateway:   mode=$GATEWAY_MODE, port=$GATEWAY_PORT, auth=on"
      [ "$NO_TELEGRAM" -eq 0 ] && log "  Telegram:  enabled, dmPolicy=pairing"
      [ "$NO_TELEGRAM" -eq 1 ] && log "  Telegram:  (skipped — запусти конфиг позже)"
      log "  Daemon:    $( [ "$SKIP_DAEMON" -eq 1 ] && echo "(skipped)" || echo "$GATEWAY_UNIT_NAME (systemd --user)" )"
      log "  Token:     ~/openclaw-gateway-token.txt (chmod 600, под $USERNAME)"
      log ""
      log "ДАЛЬШЕ — два интерактивных шага руками (скрипт их не делает):"
      log ""
      log "1) Авторизация Codex OAuth (требует браузер, в РФ — через VPN):"
      log "   ssh $USERNAME@<IP>"
      log "   openclaw models auth login --provider openai-codex"
      log "   └─ откроется URL, скопируй в браузер → залогинься в ChatGPT →"
      log "      paste вернувшийся code обратно в SSH."
      log ""
      if [ "$NO_TELEGRAM" -eq 0 ]; then
        log "2) Привязка Telegram-бота (pairing):"
        log "   a. Напиши своему боту в Telegram любое сообщение (первый DM)."
        log "   b. В отдельном SSH-окне: openclaw logs --follow"
        log "      → дождись строки с pairing code."
        log "   c. Одобри: openclaw pairing approve telegram <CODE>"
      else
        log "2) Telegram пропущен. Когда будешь готов:"
        log "   sudo bash configure-openclaw.sh --telegram-token <TOKEN>"
      fi
      log ""
    fi
  elif [ "$ERRORS_COUNT" -eq 0 ] && [ "$WARNINGS_COUNT" -gt 0 ]; then
    log "${prefix}ИТОГ: конфигурация с предупреждениями ($WARNINGS_COUNT)."
    echo "$WARNINGS_LIST" | while IFS= read -r w; do [ -n "$w" ] && log "  ! $w"; done
  else
    log "${prefix}ИТОГ: конфигурация НЕ завершена. Критичных ошибок: $ERRORS_COUNT."
    echo "$ERRORS_LIST" | while IFS= read -r e; do [ -n "$e" ] && log "  ✗ $e"; done
  fi
  log "================================================"
}

json_array_from_lines() {
  local input="$1"
  if [ -z "$input" ]; then echo "[]"; return; fi
  echo "$input" | awk '
    BEGIN { printf "[" }
    NF    { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); if (n++) printf ","; printf "\"%s\"", $0 }
    END   { printf "]" }
  '
}

print_summary_json() {
  local status="ok"
  if [ "$ERRORS_COUNT" -gt 0 ]; then status="error"
  elif [ "$WARNINGS_COUNT" -gt 0 ]; then status="warning"; fi

  local errors_json warnings_json
  errors_json="$(json_array_from_lines "$ERRORS_LIST")"
  warnings_json="$(json_array_from_lines "$WARNINGS_LIST")"

  cat <<JSON
{
  "status": "$status",
  "version": "$SCRIPT_VERSION",
  "username": "$USERNAME",
  "gateway": {
    "mode": "$GATEWAY_MODE",
    "port": $GATEWAY_PORT,
    "auth_enabled": true,
    "token_file": "${USER_HOME}/openclaw-gateway-token.txt"
  },
  "telegram": {
    "configured": $([ "$NO_TELEGRAM" -eq 0 ] && echo true || echo false),
    "dm_policy": "pairing"
  },
  "daemon": {
    "installed": $([ "$SKIP_DAEMON" -eq 1 ] && echo false || echo true),
    "unit": "$GATEWAY_UNIT_NAME"
  },
  "next_steps_for_user": [
    "openclaw models auth login --provider openai-codex",
    "(write DM to your bot) && openclaw pairing approve telegram <CODE>"
  ],
  "dry_run": $([ "$DRY_RUN" -eq 1 ] && echo true || echo false),
  "errors": $errors_json,
  "warnings": $warnings_json
}
JSON
}

# --- Main ---

log "==========================================="
log "  OpenClaw configure-openclaw  ·  v${SCRIPT_VERSION}"
log "==========================================="
log ""

if [ "$DRY_RUN" -eq 1 ]; then
  log "[DRY-RUN] Только показываю что будет сделано, систему не меняю."
  log ""
fi

# Preflight
check_root                  || exit 1
check_user_exists           || exit 1
check_openclaw_installed    || exit 1
check_telegram_args         || exit 1
check_gateway_mode_arg      || exit 1

# Actions
action_doctor_fix                         || exit 1
action_generate_gateway_token             || exit 1
action_config_gateway                     || exit 1
action_config_telegram                    || exit 1
action_config_discord_off                 || exit 1
action_config_memory_search_off           || exit 1
action_save_gateway_token_file            || exit 1
action_enable_linger                      || exit 1
action_install_systemd_unit               || exit 1
action_start_daemon                       || exit 1
action_final_doctor                       # не exit on fail — это информационный шаг

# Summary
if [ "$OUTPUT_JSON" -eq 1 ]; then
  print_summary_json
else
  print_summary_human
fi

# Exit code: 0 если всё ок, 2 если только warnings, 1 если errors
if [ "$ERRORS_COUNT" -gt 0 ]; then
  exit 1
elif [ "$WARNINGS_COUNT" -gt 0 ]; then
  exit 2
else
  exit 0
fi
