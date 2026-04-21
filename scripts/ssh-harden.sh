#!/usr/bin/env bash
#
# ssh-harden.sh — базовая безопасность VPS для OpenClaw.
#
# Запускается на VPS от имени root. Меняет состояние системы.
# Идемпотентный — повторный запуск не ломает предыдущий результат.
#
# Что делает:
#   1. Создаёт non-root пользователя (default: openclaw) с sudo.
#   2. Кладёт публичный SSH-ключ пользователя в ~/.ssh/authorized_keys.
#   3. Устанавливает fail2ban + ufw (если их нет).
#   4. Настраивает UFW: deny incoming + allow 22,80,443 + enable.
#   5. Пишет drop-in /etc/ssh/sshd_config.d/99-openclaw.conf с:
#        PasswordAuthentication no
#        PermitRootLogin no
#        PubkeyAuthentication yes
#   6. Рестартит sshd.
#
# После выполнения: доступ к серверу — ТОЛЬКО по SSH-ключу
# и ТОЛЬКО под пользователем <username> (не root).
#
# Флаги:
#   --username <name>     имя non-root пользователя (default: openclaw)
#   --pubkey <ssh-key>    публичный ключ в формате "ssh-ed25519 AAAA... comment"
#                         ОБЯЗАТЕЛЬНО. Принимается одна строка.
#   --pubkey-file <path>  альтернатива: прочитать ключ из файла
#   --ssh-port <port>     SSH-порт для UFW (default: 22)
#   --skip-fail2ban       не ставить fail2ban
#   --skip-ufw            не настраивать UFW (опасно)
#   --keep-password-auth  НЕ отключать password auth (для первого тестирования)
#   --keep-root-ssh       НЕ отключать SSH под root
#   --json                вывод в JSON (stdout), логи в stderr
#   --dry-run             показать что будет сделано, не менять систему
#   --help                справка
#
# Exit codes:
#   0  — успех
#   1  — критическая ошибка (не root, невалидный ключ, ломается sshd)
#   2  — предупреждения (ufw уже был enabled с другими правилами, и т.п.)
#
# Примеры:
#   sudo bash ssh-harden.sh --pubkey "ssh-ed25519 AAAA... user@host"
#   sudo bash ssh-harden.sh --username admin --pubkey-file /tmp/key.pub --dry-run
#

set -eo pipefail

readonly SCRIPT_VERSION="1.0.0"

# --- Параметры по умолчанию ---
USERNAME="openclaw"
PUBKEY=""
PUBKEY_FILE=""
SSH_PORT=22
SKIP_FAIL2BAN=0
SKIP_UFW=0
KEEP_PASSWORD_AUTH=0
KEEP_ROOT_SSH=0
OUTPUT_JSON=0
DRY_RUN=0

# --- Парсинг флагов ---
while [ $# -gt 0 ]; do
  case "$1" in
    --username)             USERNAME="$2"; shift 2 ;;
    --pubkey)               PUBKEY="$2"; shift 2 ;;
    --pubkey-file)          PUBKEY_FILE="$2"; shift 2 ;;
    --ssh-port)             SSH_PORT="$2"; shift 2 ;;
    --skip-fail2ban)        SKIP_FAIL2BAN=1; shift ;;
    --skip-ufw)             SKIP_UFW=1; shift ;;
    --keep-password-auth)   KEEP_PASSWORD_AUTH=1; shift ;;
    --keep-root-ssh)        KEEP_ROOT_SSH=1; shift ;;
    --json)                 OUTPUT_JSON=1; shift ;;
    --dry-run)              DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

# --json → автоматом --quiet (не смешиваем логи с JSON stdout)
QUIET=0
if [ "$OUTPUT_JSON" -eq 1 ]; then QUIET=1; fi

# --- Логирование ---
ERRORS_LIST=""
WARNINGS_LIST=""
ERRORS_COUNT=0
WARNINGS_COUNT=0
ACTIONS_LIST=""  # что реально сделали (для JSON reporting)

log() {
  if [ "$QUIET" -eq 1 ]; then
    case "${1:-}" in
      "[+]"*|"[✓]"*|"") return 0 ;;
    esac
  fi
  echo "$*" >&2
}

log_info()  { log "[+] $*"; }
log_ok()    { log "[✓] $*"; ACTIONS_LIST="${ACTIONS_LIST}${ACTIONS_LIST:+$'\n'}$*"; }
log_warn()  {
  log "[!] $*"
  WARNINGS_LIST="${WARNINGS_LIST}${WARNINGS_LIST:+$'\n'}$*"
  WARNINGS_COUNT=$((WARNINGS_COUNT + 1))
}
log_error() {
  log "[✗] $*"
  ERRORS_LIST="${ERRORS_LIST}${ERRORS_LIST:+$'\n'}$*"
  ERRORS_COUNT=$((ERRORS_COUNT + 1))
}

# --- Утилиты ---

# Обёртка: в dry-run пишет команду, не выполняет её.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) $*"
    return 0
  fi
  "$@"
}

# Безопасный rm — чтобы случайно не удалить /
safe_rm() {
  local target="$1"
  case "$target" in
    /|/*/*|/home/*|/etc/*|/tmp/*) run rm -f "$target" ;;
    *) log_error "Safety check: отказываюсь удалять '$target' (не выглядит как наш путь)"; return 1 ;;
  esac
}

# --- Валидация ---

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "Скрипт должен запускаться от root (или через sudo)."
    return 1
  fi
}

check_username() {
  # POSIX username: [a-z_][a-z0-9_-]*[$]?  — максимум 32 символа
  if ! echo "$USERNAME" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
    log_error "Недопустимое имя пользователя: '$USERNAME'. Должно начинаться с буквы, только строчные буквы/цифры/_/- (до 32 символов)."
    return 1
  fi
}

check_pubkey() {
  # Если --pubkey-file — читаем оттуда
  if [ -n "$PUBKEY_FILE" ]; then
    if [ ! -r "$PUBKEY_FILE" ]; then
      log_error "Файл с ключом не читается: $PUBKEY_FILE"
      return 1
    fi
    PUBKEY="$(cat "$PUBKEY_FILE")"
  fi

  if [ -z "$PUBKEY" ]; then
    log_error "Нужно указать --pubkey или --pubkey-file. Без SSH-ключа мы потеряем доступ к серверу."
    return 1
  fi

  # Минимальная валидация формата
  if ! echo "$PUBKEY" | grep -Eq '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-(nistp256|nistp384|nistp521)) AAAA[A-Za-z0-9+/=]+( .*)?$'; then
    log_error "Ключ не в формате OpenSSH. Ожидается 'ssh-ed25519 AAAA... comment' или аналогичное."
    log_error "Получено (первые 60 символов): '$(echo "$PUBKEY" | cut -c1-60)...'"
    return 1
  fi

  log_ok "Публичный ключ валиден (тип: $(echo "$PUBKEY" | awk '{print $1}'))"
}

check_port() {
  if ! echo "$SSH_PORT" | grep -Eq '^[0-9]+$' || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    log_error "Невалидный SSH-порт: '$SSH_PORT'. Должен быть 1-65535."
    return 1
  fi
}

# --- Действия ---

action_create_user() {
  log_info "Создаю пользователя '$USERNAME'..."
  if id "$USERNAME" >/dev/null 2>&1; then
    log_ok "Пользователь '$USERNAME' уже существует (пропускаю создание)"
  else
    run useradd --create-home --shell /bin/bash "$USERNAME"
    log_ok "Создан пользователь '$USERNAME' с домашней директорией /home/$USERNAME"
  fi

  # Добавить в sudo (Debian/Ubuntu) — если не добавлен.
  # getent/id — read-only команды, безопасно выполнять всегда (включая dry-run).
  if getent group sudo >/dev/null 2>&1; then
    if id -nG "$USERNAME" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
      log_ok "'$USERNAME' уже в группе sudo"
    else
      run usermod -aG sudo "$USERNAME"
      if [ "$DRY_RUN" -eq 0 ]; then
        log_ok "'$USERNAME' добавлен в группу sudo"
      fi
    fi
  fi

  # NOPASSWD sudo для автоматизации AI-агентом.
  # ВАЖНО: только для этого пользователя, в отдельном drop-in файле.
  local sudoers_file="/etc/sudoers.d/90-$USERNAME"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) echo '$USERNAME ALL=(ALL) NOPASSWD:ALL' > $sudoers_file"
  else
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
    chmod 440 "$sudoers_file"
    # Проверка синтаксиса sudoers до применения
    if ! visudo -c -f "$sudoers_file" >/dev/null 2>&1; then
      safe_rm "$sudoers_file"
      log_error "Синтаксическая ошибка в $sudoers_file — удалил, восстанавливаю безопасное состояние"
      return 1
    fi
  fi
  log_ok "Настроен passwordless sudo для '$USERNAME' (drop-in $sudoers_file)"
}

action_install_ssh_key() {
  log_info "Устанавливаю SSH-ключ для '$USERNAME'..."
  local ssh_dir="/home/$USERNAME/.ssh"
  local auth_file="$ssh_dir/authorized_keys"

  run mkdir -p "$ssh_dir"
  run chmod 700 "$ssh_dir"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) добавить ключ в $auth_file"
  else
    # Создаём файл если нет, и добавляем ключ если ещё не добавлен
    touch "$auth_file"
    if grep -qxF "$PUBKEY" "$auth_file"; then
      log_ok "Ключ уже присутствует в $auth_file"
    else
      echo "$PUBKEY" >> "$auth_file"
      log_ok "Ключ добавлен в $auth_file"
    fi
    chmod 600 "$auth_file"
    chown -R "$USERNAME:$USERNAME" "$ssh_dir"
  fi
}

action_apt_update() {
  log_info "Обновляю индекс пакетов (apt update)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) apt-get update -qq"
  else
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    log_ok "apt-get update завершён"
  fi
}

action_install_fail2ban() {
  if [ "$SKIP_FAIL2BAN" -eq 1 ]; then
    log_info "Пропускаю установку fail2ban (--skip-fail2ban)"
    return 0
  fi

  log_info "Устанавливаю fail2ban..."
  if command -v fail2ban-server >/dev/null 2>&1; then
    log_ok "fail2ban уже установлен"
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      log "      (dry-run) apt-get install -y fail2ban"
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null
      log_ok "fail2ban установлен"
    fi
  fi

  run systemctl enable --now fail2ban >/dev/null 2>&1
  log_ok "fail2ban активирован (systemctl enable --now)"
}

action_setup_ufw() {
  if [ "$SKIP_UFW" -eq 1 ]; then
    log_info "Пропускаю настройку UFW (--skip-ufw)"
    return 0
  fi

  log_info "Настраиваю UFW (firewall)..."

  if ! command -v ufw >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "      (dry-run) apt-get install -y ufw"
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null
    fi
    log_ok "UFW установлен"
  fi

  # Применяем правила (идемпотентно — ufw принимает тот же rule повторно без ошибок)
  run ufw --force default deny incoming
  run ufw --force default allow outgoing
  run ufw allow "$SSH_PORT"/tcp comment "SSH"
  run ufw allow 80/tcp comment "HTTP (future nginx)"
  run ufw allow 443/tcp comment "HTTPS (future nginx)"

  # Включаем UFW (--force = без интерактивного подтверждения)
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) ufw --force enable"
  else
    ufw --force enable >/dev/null
  fi
  log_ok "UFW активен: deny incoming; allow $SSH_PORT,80,443"
}

action_harden_ssh() {
  log_info "Настраиваю SSH-hardening..."

  local dropin_dir="/etc/ssh/sshd_config.d"
  local dropin_file="$dropin_dir/99-openclaw.conf"

  # Проверим что main sshd_config включает sshd_config.d (Ubuntu 22+/Debian 12 — по умолчанию да)
  if [ -f /etc/ssh/sshd_config ] && ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config; then
    log_warn "/etc/ssh/sshd_config не содержит Include /etc/ssh/sshd_config.d/*.conf — drop-in может не примениться"
  fi

  run mkdir -p "$dropin_dir"

  # Явные значения yes/no вместо хитрых bash-parameter-expansion, чтобы
  # не получить "yes0" при KEEP_*=0 (баг в предыдущей версии).
  local pw_auth="no"
  local root_ssh="no"
  [ "$KEEP_PASSWORD_AUTH" -eq 1 ] && pw_auth="yes"
  [ "$KEEP_ROOT_SSH" -eq 1 ] && root_ssh="yes"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) создать $dropin_file со следующим содержимым:"
    log "        PasswordAuthentication $pw_auth"
    log "        PermitRootLogin $root_ssh"
    log "        PubkeyAuthentication yes"
  else
    cat > "$dropin_file" <<EOF
# Written by ssh-harden.sh v${SCRIPT_VERSION} — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Do not edit by hand; re-run ssh-harden.sh to update.

PasswordAuthentication $pw_auth
PermitRootLogin $root_ssh
PubkeyAuthentication yes
EOF
    chmod 644 "$dropin_file"
    log_ok "SSH-конфиг записан в $dropin_file"
  fi

  # Проверка синтаксиса до рестарта sshd — критично, чтобы не сломать доступ
  if [ "$DRY_RUN" -eq 0 ]; then
    if ! sshd -t 2>/dev/null; then
      log_error "sshd -t не прошёл валидацию. Удаляю $dropin_file и оставляю старый конфиг."
      safe_rm "$dropin_file"
      return 1
    fi
  fi
  log_ok "sshd конфигурация прошла валидацию (sshd -t)"

  # Рестартим sshd
  # На Ubuntu 22 сервис называется 'ssh', на Debian — 'ssh' или 'sshd'
  local ssh_service="ssh"
  if ! systemctl list-unit-files "$ssh_service.service" >/dev/null 2>&1; then
    ssh_service="sshd"
  fi
  run systemctl reload "$ssh_service" 2>/dev/null || run systemctl restart "$ssh_service"
  log_ok "sshd перезапущен ($ssh_service)"
}

# --- Итог ---

print_summary_human() {
  log ""
  log "================================================"
  local prefix=""
  [ "$DRY_RUN" -eq 1 ] && prefix="[DRY-RUN] "

  if [ "$ERRORS_COUNT" -eq 0 ] && [ "$WARNINGS_COUNT" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "${prefix}ИТОГ: все проверки прошли. Система НЕ менялась (dry-run)."
      log "Чтобы применить изменения — запусти ту же команду без флага --dry-run."
    else
      log "ИТОГ: hardening завершён. ✓"
      log ""
      log "Теперь подключайся так:"
      log "  ssh $USERNAME@<IP>"
      log ""
      log "Если это НЕ сработает — сразу запусти откат в этом же терминале:"
      log "  ssh root@<IP> 'rm /etc/ssh/sshd_config.d/99-openclaw.conf && systemctl reload ssh'"
    fi
  elif [ "$ERRORS_COUNT" -eq 0 ]; then
    log "${prefix}ИТОГ: ${WARNINGS_COUNT} предупреждений."
    echo "$WARNINGS_LIST" | while IFS= read -r w; do [ -n "$w" ] && log "  ! $w"; done
  else
    log "${prefix}ИТОГ: НЕ завершено. Критичных ошибок: ${ERRORS_COUNT}."
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

  local errors_json warnings_json actions_json
  errors_json="$(json_array_from_lines "$ERRORS_LIST")"
  warnings_json="$(json_array_from_lines "$WARNINGS_LIST")"
  actions_json="$(json_array_from_lines "$ACTIONS_LIST")"

  cat <<JSON
{
  "status": "$status",
  "version": "$SCRIPT_VERSION",
  "username": "$USERNAME",
  "ssh_port": $SSH_PORT,
  "password_auth_disabled": $([ "$KEEP_PASSWORD_AUTH" -eq 0 ] && echo true || echo false),
  "root_ssh_disabled": $([ "$KEEP_ROOT_SSH" -eq 0 ] && echo true || echo false),
  "fail2ban_installed": $([ "$SKIP_FAIL2BAN" -eq 0 ] && echo true || echo false),
  "ufw_enabled": $([ "$SKIP_UFW" -eq 0 ] && echo true || echo false),
  "dry_run": $([ "$DRY_RUN" -eq 1 ] && echo true || echo false),
  "actions": $actions_json,
  "errors": $errors_json,
  "warnings": $warnings_json
}
JSON
}

# --- Main ---

log "==========================================="
log "  OpenClaw ssh-harden  ·  v${SCRIPT_VERSION}"
log "==========================================="
log ""

if [ "$DRY_RUN" -eq 1 ]; then
  log "[DRY-RUN] Только показываю что будет сделано, систему не меняю."
  log ""
fi

# Preflight-valid
check_root             || exit 1
check_username         || exit 1
check_pubkey           || exit 1
check_port             || exit 1

# Действия
action_create_user     || exit 1
action_install_ssh_key || exit 1

if [ "$SKIP_FAIL2BAN" -eq 0 ] || [ "$SKIP_UFW" -eq 0 ]; then
  action_apt_update    || exit 1
fi

action_install_fail2ban
action_setup_ufw
action_harden_ssh      || exit 1

# Итог
if [ "$OUTPUT_JSON" -eq 1 ]; then
  print_summary_json
else
  print_summary_human
fi

if [ "$ERRORS_COUNT" -gt 0 ]; then
  exit 1
elif [ "$WARNINGS_COUNT" -gt 0 ]; then
  exit 2
else
  exit 0
fi
