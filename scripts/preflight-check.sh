#!/usr/bin/env bash
#
# preflight-check.sh — проверка готовности VPS к установке OpenClaw.
#
# Запускается на целевом VPS после первого SSH-подключения.
# НЕ меняет состояние системы — только читает.
#
# Проверяет:
#   - ОС (Ubuntu 22.04+ / Debian 12+)
#   - Архитектуру (x86_64 или aarch64)
#   - RAM (минимум 1.5 GB)
#   - Диск (минимум 5 GB свободно на /)
#   - Интернет (HTTPS до openclaw.ai)
#   - Node.js (если установлен — версия ≥ 22.14)
#   - systemd (нужен для --install-daemon)
#   - curl (нужен для install.sh)
#
# Флаги:
#   --json      вывод в JSON (stdout только JSON, логи в stderr)
#   --quiet     без промежуточных [+] строк
#   --help      показать справку
#
# Exit codes:
#   0  — все проверки пройдены
#   1  — критичные блокеры (ОС не та, нет интернета, мало ресурсов)
#   2  — только warnings
#
# Запуск:
#   bash preflight-check.sh
#   bash preflight-check.sh --json
#   ssh root@<IP> 'bash -s' < preflight-check.sh
#

set -eo pipefail

# --- Конфигурация порогов ---
MIN_NODE_MAJOR=22
MIN_NODE_MINOR=14
MIN_RAM_MB=1500
MIN_DISK_GB=5
SUPPORTED_UBUNTU_MIN=22
SUPPORTED_DEBIAN_MIN=12

# --- Парсинг флагов ---
OUTPUT_JSON=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --json)  OUTPUT_JSON=1 ;;
    --quiet) QUIET=1 ;;
    --help|-h)
      sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

# --- State (плоские переменные для совместимости с bash 3.2) ---
STATE_OS_NAME="unknown"
STATE_OS_VERSION="unknown"
STATE_OS_SUPPORTED="false"
STATE_ARCH=""
STATE_RAM_MB=0
STATE_RAM_OK="false"
STATE_DISK_GB=0
STATE_DISK_OK="false"
STATE_INTERNET_OK="false"
STATE_NODE_INSTALLED="false"
STATE_NODE_VERSION=""
STATE_NODE_OK="false"
STATE_SYSTEMD_OK="false"
STATE_CURL_OK="false"

ERRORS_LIST=""
WARNINGS_LIST=""
ERRORS_COUNT=0
WARNINGS_COUNT=0

# --- Логирование (в stderr, чтобы stdout был чистым для --json) ---
log() {
  if [ "$QUIET" -eq 1 ] && [ "${1:-}" = "[+]" ]; then return 0; fi
  echo "$*" >&2
}

log_info()  { log "[+] $*"; }
log_ok()    { log "[✓] $*"; }
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

# --- Проверки ---

check_os() {
  log_info "Проверяю ОС..."
  if [ ! -f /etc/os-release ]; then
    log_error "Файл /etc/os-release не найден. Скрипт должен запускаться на Linux (Ubuntu/Debian)."
    return
  fi

  # shellcheck source=/dev/null
  . /etc/os-release
  STATE_OS_NAME="${NAME:-unknown}"
  STATE_OS_VERSION="${VERSION_ID:-unknown}"

  local major
  case "${ID:-}" in
    ubuntu)
      major="${VERSION_ID%%.*}"
      if [ "$major" -ge "$SUPPORTED_UBUNTU_MIN" ] 2>/dev/null; then
        log_ok "ОС: ${NAME} ${VERSION_ID} (поддерживается)"
        STATE_OS_SUPPORTED="true"
      else
        log_error "ОС: ${NAME} ${VERSION_ID} слишком старая. Нужен Ubuntu ${SUPPORTED_UBUNTU_MIN}.04+."
      fi
      ;;
    debian)
      major="${VERSION_ID%%.*}"
      if [ "$major" -ge "$SUPPORTED_DEBIAN_MIN" ] 2>/dev/null; then
        log_ok "ОС: ${NAME} ${VERSION_ID} (поддерживается)"
        STATE_OS_SUPPORTED="true"
      else
        log_error "ОС: ${NAME} ${VERSION_ID} слишком старая. Нужен Debian ${SUPPORTED_DEBIAN_MIN}+."
      fi
      ;;
    *)
      log_error "ОС ${NAME:-?} не поддерживается. Нужен Ubuntu ${SUPPORTED_UBUNTU_MIN}.04+ или Debian ${SUPPORTED_DEBIAN_MIN}+."
      ;;
  esac
}

check_arch() {
  log_info "Проверяю архитектуру..."
  STATE_ARCH="$(uname -m)"

  case "$STATE_ARCH" in
    x86_64|amd64)
      log_ok "Архитектура: ${STATE_ARCH} (поддерживается)"
      ;;
    aarch64|arm64)
      log_ok "Архитектура: ${STATE_ARCH} (поддерживается — ARM)"
      ;;
    *)
      log_error "Архитектура ${STATE_ARCH} не поддерживается. Нужен x86_64 или aarch64/arm64."
      ;;
  esac
}

check_ram() {
  log_info "Проверяю RAM..."
  if ! command -v free >/dev/null 2>&1; then
    log_warn "Команда 'free' не найдена — пропускаю проверку RAM."
    return
  fi

  STATE_RAM_MB="$(free -m | awk '/^Mem:/ {print $2}')"
  if [ -z "$STATE_RAM_MB" ]; then STATE_RAM_MB=0; fi

  if [ "$STATE_RAM_MB" -ge "$MIN_RAM_MB" ] 2>/dev/null; then
    log_ok "RAM: ${STATE_RAM_MB} MB (≥ ${MIN_RAM_MB} MB)"
    STATE_RAM_OK="true"
  else
    log_error "RAM: ${STATE_RAM_MB} MB. Нужно минимум ${MIN_RAM_MB} MB."
  fi
}

check_disk() {
  log_info "Проверяю свободное место на /..."
  local disk_kb
  # GNU df --output=avail на Ubuntu/Debian; BSD df -k без --output на macOS
  if df --output=avail / >/dev/null 2>&1; then
    disk_kb="$(df --output=avail / | tail -1 | tr -d ' ')"
  else
    # fallback: BSD-style (macOS) — 4-я колонка в df -k
    disk_kb="$(df -k / | awk 'NR==2 {print $4}')"
  fi

  if [ -z "$disk_kb" ] || [ "$disk_kb" = "0" ]; then
    log_warn "Не смог определить свободное место на /."
    return
  fi

  STATE_DISK_GB=$((disk_kb / 1024 / 1024))

  if [ "$STATE_DISK_GB" -ge "$MIN_DISK_GB" ] 2>/dev/null; then
    log_ok "Диск: ${STATE_DISK_GB} GB свободно на / (≥ ${MIN_DISK_GB} GB)"
    STATE_DISK_OK="true"
  else
    log_error "Диск: ${STATE_DISK_GB} GB свободно. Нужно минимум ${MIN_DISK_GB} GB."
  fi
}

check_internet() {
  log_info "Проверяю доступ к openclaw.ai..."
  if ! command -v curl >/dev/null 2>&1; then
    log_error "Команда 'curl' не установлена — требуется для загрузки установщика."
    return
  fi
  STATE_CURL_OK="true"

  local http_code
  http_code="$(curl -fsSI --max-time 10 -o /dev/null -w '%{http_code}' https://openclaw.ai/install.sh 2>/dev/null || echo '000')"

  if [ "$http_code" = "200" ]; then
    log_ok "Интернет: openclaw.ai/install.sh доступен (HTTP $http_code)"
    STATE_INTERNET_OK="true"
  else
    log_error "Не удалось достучаться до openclaw.ai/install.sh (HTTP $http_code). Проверь интернет и DNS."
  fi
}

check_node() {
  log_info "Проверяю Node.js..."
  if ! command -v node >/dev/null 2>&1; then
    log_info "Node.js не установлен — это ок, установим позже."
    return
  fi

  STATE_NODE_INSTALLED="true"
  STATE_NODE_VERSION="$(node --version 2>/dev/null | sed 's/^v//')"

  local major="${STATE_NODE_VERSION%%.*}"
  local rest="${STATE_NODE_VERSION#*.}"
  local minor="${rest%%.*}"

  if [ -z "$major" ] || [ -z "$minor" ]; then
    log_warn "Не смог распарсить версию Node.js: ${STATE_NODE_VERSION}"
    return
  fi

  if [ "$major" -gt "$MIN_NODE_MAJOR" ] || { [ "$major" -eq "$MIN_NODE_MAJOR" ] && [ "$minor" -ge "$MIN_NODE_MINOR" ]; }; then
    log_ok "Node.js: v${STATE_NODE_VERSION} (≥ v${MIN_NODE_MAJOR}.${MIN_NODE_MINOR})"
    STATE_NODE_OK="true"
  else
    log_warn "Node.js: v${STATE_NODE_VERSION} устарел. Рекомендуется ≥ v${MIN_NODE_MAJOR}.${MIN_NODE_MINOR} — обновим при установке."
  fi
}

check_systemd() {
  log_info "Проверяю systemd..."
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    log_ok "systemd работает (нужен для --install-daemon)"
    STATE_SYSTEMD_OK="true"
  else
    log_error "systemd не обнаружен. OpenClaw daemon не запустится."
  fi
}

# --- Итоговый вывод ---

print_summary_human() {
  log ""
  log "================================================"
  if [ "$ERRORS_COUNT" -eq 0 ] && [ "$WARNINGS_COUNT" -eq 0 ]; then
    log "ИТОГ: все проверки пройдены. Можно устанавливать OpenClaw. ✓"
  elif [ "$ERRORS_COUNT" -eq 0 ]; then
    log "ИТОГ: есть предупреждения (${WARNINGS_COUNT}), но установка возможна."
    echo "$WARNINGS_LIST" | while IFS= read -r w; do [ -n "$w" ] && log "  ! $w"; done
  else
    log "ИТОГ: установка невозможна. Критичных проблем: ${ERRORS_COUNT}."
    echo "$ERRORS_LIST" | while IFS= read -r e; do [ -n "$e" ] && log "  ✗ $e"; done
  fi
  log "================================================"
}

# Простая функция: список строк (через \n) → JSON-массив
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
  "os": {
    "name": "${STATE_OS_NAME}",
    "version": "${STATE_OS_VERSION}",
    "supported": ${STATE_OS_SUPPORTED}
  },
  "arch": "${STATE_ARCH}",
  "ram_mb": ${STATE_RAM_MB},
  "ram_ok": ${STATE_RAM_OK},
  "disk_gb": ${STATE_DISK_GB},
  "disk_ok": ${STATE_DISK_OK},
  "internet_ok": ${STATE_INTERNET_OK},
  "curl_ok": ${STATE_CURL_OK},
  "systemd_ok": ${STATE_SYSTEMD_OK},
  "node": {
    "installed": ${STATE_NODE_INSTALLED},
    "version": "${STATE_NODE_VERSION}",
    "ok": ${STATE_NODE_OK}
  },
  "errors": $errors_json,
  "warnings": $warnings_json
}
JSON
}

# --- Main ---

log "==========================================="
log "  OpenClaw preflight-check  ·  v1.0.0"
log "==========================================="
log ""

check_os
check_arch
check_ram
check_disk
check_internet
check_node
check_systemd

if [ "$OUTPUT_JSON" -eq 1 ]; then
  print_summary_json
else
  print_summary_human
fi

# Exit code
if [ "$ERRORS_COUNT" -gt 0 ]; then
  exit 1
elif [ "$WARNINGS_COUNT" -gt 0 ]; then
  exit 2
else
  exit 0
fi
