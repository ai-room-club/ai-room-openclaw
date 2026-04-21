#!/usr/bin/env bash
#
# install-openclaw.sh — установка OpenClaw CLI на VPS.
#
# Запускается на VPS от имени root (или через sudo). Меняет состояние системы.
# Идемпотентный: повторный запуск обнаружит установленный Node/OpenClaw
# и пропустит уже сделанное.
#
# Что делает:
#   1. Устанавливает Node.js <major> через nodesource (Ubuntu/Debian).
#   2. Под указанным non-root пользователем (default: openclaw):
#        curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
#      Флаг --no-onboard обязателен: иначе install.sh запускает интерактивный
#      wizard, который падает на /dev/tty в неинтерактивном SSH-сессии.
#      Onboarding проводится отдельно в configure-openclaw.sh.
#   3. Гарантирует, что $HOME/.npm-global/bin в PATH пользователя
#      (install.sh иногда только warn'ит вместо авто-добавления).
#   4. Проверяет, что openclaw CLI доступен в PATH пользователя.
#   5. Сверяет версию с минимальной (дефолт 2026.1.29 = патч CVE-2026-25253).
#   6. Запускает `openclaw doctor` и анализирует вывод.
#
# Почему под non-root пользователем:
#   install.sh кладёт бинарники в ~/.npm-global/bin и ~/.openclaw, и потом
#   onboard --install-daemon создаёт systemd user unit (под этим же юзером).
#   Если поставить под root, systemd user unit у openclaw работать не будет.
#
# Флаги:
#   --username <name>         имя non-root пользователя (default: openclaw)
#   --node-version <major>    Node.js major version (default: 22; min 22)
#   --min-openclaw-version <ver>  минимум (default: 2026.1.29 — CVE patch)
#   --skip-doctor             не запускать openclaw doctor
#   --json                    вывод в JSON (stdout), логи в stderr
#   --dry-run                 preview без изменений
#   --help                    справка
#
# Exit codes:
#   0 — успех: Node + OpenClaw установлены, версия >= min, doctor без critical
#   1 — критично: не root, старая версия OpenClaw, doctor critical
#   2 — warnings: doctor нашёл замечания, но не critical
#
# Пример:
#   sudo bash install-openclaw.sh --username openclaw
#   ssh openclaw@<IP> 'curl -fsSL <repo-url>/install-openclaw.sh | sudo bash'
#

set -eo pipefail

readonly SCRIPT_VERSION="1.0.0"

# --- Defaults ---
USERNAME="openclaw"
NODE_VERSION="22"
MIN_OPENCLAW_VERSION="2026.1.29"
SKIP_DOCTOR=0
OUTPUT_JSON=0
DRY_RUN=0

# --- Flags parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --username)                USERNAME="$2"; shift 2 ;;
    --node-version)            NODE_VERSION="$2"; shift 2 ;;
    --min-openclaw-version)    MIN_OPENCLAW_VERSION="$2"; shift 2 ;;
    --skip-doctor)             SKIP_DOCTOR=1; shift ;;
    --json)                    OUTPUT_JSON=1; shift ;;
    --dry-run)                 DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '3,42p' "$0" | sed 's/^# \{0,1\}//'
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

INSTALLED_NODE_VERSION=""
INSTALLED_OPENCLAW_VERSION=""
DOCTOR_CRITICAL=0
DOCTOR_WARNINGS=0

# --- Logging ---
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

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) $*"
    return 0
  fi
  "$@"
}

# Запустить команду от имени $USERNAME с полным окружением (загрузить .bashrc/.profile).
# -i эмулирует interactive login, чтобы PATH включал ~/.npm-global/bin и ~/.openclaw/bin.
run_as_user() {
  local cmd="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run, as $USERNAME) $cmd"
    return 0
  fi
  sudo -u "$USERNAME" -i bash -lc "$cmd"
}

# Для чтения — возвращаем stdout (не пишем в лог). В dry-run возвращаем пустую строку.
capture_as_user() {
  local cmd="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    return 0
  fi
  sudo -u "$USERNAME" -i bash -lc "$cmd" 2>/dev/null || true
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
    log_error "Пользователь '$USERNAME' не существует. Сначала запусти ssh-harden.sh."
    return 1
  fi
  log_ok "Пользователь '$USERNAME' найден"
}

check_node_major_arg() {
  if ! echo "$NODE_VERSION" | grep -Eq '^[0-9]+$'; then
    log_error "Некорректный --node-version: '$NODE_VERSION'. Ожидается число (например, 22)."
    return 1
  fi
  if [ "$NODE_VERSION" -lt 22 ]; then
    log_error "Node.js < 22 не поддерживается OpenClaw. Используй 22 или выше."
    return 1
  fi
}

# --- Version compare: returns 0 if $1 >= $2, else 1. Works with X.Y.Z semver ---
version_ge() {
  # normalise: split by dot and lpad each to 4 digits, then string compare
  local a b
  a="$(echo "$1" | awk -F. '{printf "%04d.%04d.%04d\n", $1+0, $2+0, $3+0}')"
  b="$(echo "$2" | awk -F. '{printf "%04d.%04d.%04d\n", $1+0, $2+0, $3+0}')"
  [ "$a" ">=" "$b" ] 2>/dev/null || true  # bash string compare
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort | tail -1)" = "$a" ]
}

# --- Actions ---

action_install_node() {
  log_info "Проверяю Node.js ${NODE_VERSION}+..."

  if command -v node >/dev/null 2>&1; then
    INSTALLED_NODE_VERSION="$(node --version 2>/dev/null | sed 's/^v//')"
    local installed_major="${INSTALLED_NODE_VERSION%%.*}"
    if [ "$installed_major" -ge "$NODE_VERSION" ] 2>/dev/null; then
      log_ok "Node.js v${INSTALLED_NODE_VERSION} уже установлен (>= v${NODE_VERSION})"
      return 0
    else
      log_warn "Node.js v${INSTALLED_NODE_VERSION} старее требуемой v${NODE_VERSION} — переустанавливаю"
    fi
  fi

  log_info "Устанавливаю Node.js ${NODE_VERSION} через nodesource..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run) curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -"
    log "      (dry-run) apt-get install -y nodejs"
    INSTALLED_NODE_VERSION="(dry-run)"
    log_ok "Node.js ${NODE_VERSION} установлен через nodesource"
    return 0
  fi

  # Установка nodesource apt-repo
  DEBIAN_FRONTEND=noninteractive curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" \
    | DEBIAN_FRONTEND=noninteractive bash - >/dev/null 2>&1

  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null

  INSTALLED_NODE_VERSION="$(node --version 2>/dev/null | sed 's/^v//')"
  log_ok "Node.js v${INSTALLED_NODE_VERSION} установлен через nodesource"
}

action_install_openclaw() {
  log_info "Проверяю текущую установку OpenClaw под '$USERNAME'..."

  # Если openclaw уже в PATH пользователя — фиксируем версию и выходим
  local current_version
  current_version="$(capture_as_user 'command -v openclaw >/dev/null 2>&1 && openclaw --version 2>/dev/null')"
  if [ -n "$current_version" ]; then
    # openclaw --version часто выводит "openclaw/2026.4.15" или "v2026.4.15" или просто версию
    INSTALLED_OPENCLAW_VERSION="$(echo "$current_version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    log_ok "OpenClaw уже установлен: v${INSTALLED_OPENCLAW_VERSION:-?}"

    if version_ge "$INSTALLED_OPENCLAW_VERSION" "$MIN_OPENCLAW_VERSION"; then
      log_ok "Версия удовлетворяет минимуму (>= v${MIN_OPENCLAW_VERSION})"
      return 0
    else
      log_warn "Установленная v${INSTALLED_OPENCLAW_VERSION} < v${MIN_OPENCLAW_VERSION} — рекомендуется обновление"
      # Не блокируем — дальнейший install скрипт обновит
    fi
  fi

  log_info "Устанавливаю OpenClaw через официальный install.sh (под '$USERNAME')..."
  log_info "  (--no-onboard: wizard требует TTY, в SSH его нет; onboarding — в configure-openclaw.sh)"

  # Run install.sh от имени пользователя openclaw.
  # --no-onboard: пропустить интерактивный setup (иначе /dev/tty: No such device).
  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run, as $USERNAME) curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard"
    INSTALLED_OPENCLAW_VERSION="(dry-run)"
    log_ok "OpenClaw установлен (dry-run)"
    return 0
  fi

  # stdout/stderr НЕ глушим — install.sh печатает понятный прогресс, пусть пользователь видит.
  if ! run_as_user "curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard"; then
    log_error "install.sh от openclaw.ai завершился ошибкой."
    log_error "Попробуй вручную: sudo -u $USERNAME -i bash -lc 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard'"
    return 1
  fi

  # install.sh кладёт openclaw в ~/.npm-global/bin, но не всегда добавляет этот
  # путь в PATH пользователя (warn'ит вместо этого). Правим руками — идемпотентно.
  local user_home profile
  user_home="$(getent passwd "$USERNAME" | cut -d: -f6)"
  profile="${user_home}/.bashrc"

  if [ -f "$profile" ] && ! grep -qF ".npm-global/bin" "$profile" 2>/dev/null; then
    log_info "Добавляю \$HOME/.npm-global/bin в PATH ($profile)..."
    {
      echo ""
      echo "# OpenClaw: npm global bin dir (added by install-openclaw.sh)"
      echo 'export PATH="$HOME/.npm-global/bin:$PATH"'
    } >> "$profile"
    chown "$USERNAME:$USERNAME" "$profile"
    log_ok "PATH обновлён в $profile"
  fi

  # Проверка: openclaw доступен в PATH пользователя (новый login shell подхватит .bashrc).
  INSTALLED_OPENCLAW_VERSION="$(capture_as_user 'openclaw --version 2>/dev/null' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

  if [ -z "$INSTALLED_OPENCLAW_VERSION" ]; then
    log_error "После install.sh команда 'openclaw' не найдена в PATH пользователя '$USERNAME'."
    log_error "Проверь: sudo -u $USERNAME -i bash -lc 'command -v openclaw; echo \$PATH'"
    return 1
  fi

  log_ok "OpenClaw v${INSTALLED_OPENCLAW_VERSION} установлен"
}

action_verify_min_version() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log_info "(dry-run) Пропускаю проверку минимальной версии"
    return 0
  fi

  if [ -z "$INSTALLED_OPENCLAW_VERSION" ]; then
    log_error "Версия OpenClaw не определена — не могу проверить минимум."
    return 1
  fi

  if version_ge "$INSTALLED_OPENCLAW_VERSION" "$MIN_OPENCLAW_VERSION"; then
    log_ok "Версия v${INSTALLED_OPENCLAW_VERSION} >= минимума v${MIN_OPENCLAW_VERSION} (CVE-2026-25253 закрыта)"
  else
    log_error "v${INSTALLED_OPENCLAW_VERSION} < v${MIN_OPENCLAW_VERSION} — есть риск CVE-2026-25253. Обнови: openclaw update или переустанови."
    return 1
  fi
}

action_run_doctor() {
  if [ "$SKIP_DOCTOR" -eq 1 ]; then
    log_info "Пропускаю openclaw doctor (--skip-doctor)"
    return 0
  fi

  log_info "Запускаю openclaw doctor..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "      (dry-run, as $USERNAME) openclaw doctor"
    log_ok "openclaw doctor (dry-run)"
    return 0
  fi

  local doctor_output
  doctor_output="$(capture_as_user 'openclaw doctor 2>&1')"

  # Минимальный анализ: ищем явные маркеры
  DOCTOR_CRITICAL=$(echo "$doctor_output" | grep -ciE '(critical|fatal|error:)' || true)
  DOCTOR_WARNINGS=$(echo "$doctor_output" | grep -ciE '^warning|warn:' || true)

  if [ "$DOCTOR_CRITICAL" -gt 0 ]; then
    log_error "openclaw doctor нашёл $DOCTOR_CRITICAL critical issue(s). Вывод:"
    log ""
    echo "$doctor_output" | while IFS= read -r line; do log "  $line"; done
  elif [ "$DOCTOR_WARNINGS" -gt 0 ]; then
    log_warn "openclaw doctor: $DOCTOR_WARNINGS warning(s). Рекомендуется просмотр."
  else
    log_ok "openclaw doctor: проблем не обнаружено"
  fi
}

# --- Summary ---

print_summary_human() {
  log ""
  log "================================================"
  local prefix=""
  [ "$DRY_RUN" -eq 1 ] && prefix="[DRY-RUN] "

  if [ "$ERRORS_COUNT" -eq 0 ] && [ "$WARNINGS_COUNT" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "${prefix}ИТОГ: все проверки прошли. Система НЕ менялась (dry-run)."
    else
      log "ИТОГ: OpenClaw установлен. ✓"
      log ""
      log "  Node.js:   v${INSTALLED_NODE_VERSION}"
      log "  OpenClaw:  v${INSTALLED_OPENCLAW_VERSION}"
      log ""
      log "Дальше — запустить onboarding под пользователем '$USERNAME':"
      log "  ssh $USERNAME@<IP>"
      log "  openclaw onboard --install-daemon"
    fi
  elif [ "$ERRORS_COUNT" -eq 0 ]; then
    log "${prefix}ИТОГ: установка с предупреждениями (${WARNINGS_COUNT})."
    echo "$WARNINGS_LIST" | while IFS= read -r w; do [ -n "$w" ] && log "  ! $w"; done
  else
    log "${prefix}ИТОГ: установка НЕ завершена. Критичных ошибок: ${ERRORS_COUNT}."
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
  "node_version": "$INSTALLED_NODE_VERSION",
  "openclaw_version": "$INSTALLED_OPENCLAW_VERSION",
  "min_openclaw_version": "$MIN_OPENCLAW_VERSION",
  "doctor_critical": $DOCTOR_CRITICAL,
  "doctor_warnings": $DOCTOR_WARNINGS,
  "dry_run": $([ "$DRY_RUN" -eq 1 ] && echo true || echo false),
  "actions": $actions_json,
  "errors": $errors_json,
  "warnings": $warnings_json
}
JSON
}

# --- Main ---

log "==========================================="
log "  OpenClaw install-openclaw  ·  v${SCRIPT_VERSION}"
log "==========================================="
log ""

if [ "$DRY_RUN" -eq 1 ]; then
  log "[DRY-RUN] Только показываю что будет сделано, систему не меняю."
  log ""
fi

# Preflight
check_root              || exit 1
check_user_exists       || exit 1
check_node_major_arg    || exit 1

# Actions
action_install_node                             || exit 1
action_install_openclaw                         || exit 1
[ "$DRY_RUN" -eq 0 ] && action_verify_min_version || true
action_run_doctor

# Summary
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
