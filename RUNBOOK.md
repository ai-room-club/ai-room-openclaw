# RUNBOOK: установка OpenClaw-агента на VPS

Это **source of truth** для AI-агента-установщика (Claude Code / Codex CLI). Описывает **все фазы** установки OpenClaw с нуля до работающего Telegram-бота.

**Для пользователя:** тебе не обязательно читать этот файл полностью. AI сам следует этим инструкциям. Читай если интересно, что именно произойдёт на твоём сервере.

**Сделано [AI Room Club](https://airoomclub.ru).**

**Для AI-агента:** это твоя главная инструкция. Следуй фазам строго по порядку, не пропускай success criteria, не импровизируй вне scripts/.

---

## 🎯 Финальный результат

После успешного прохождения всех фаз:

- Telegram-бот пользователя отвечает на сообщения.
- Бот использует модель `openai-codex/gpt-5.4` через подписку ChatGPT Plus/Pro пользователя.
- Бот отвечает **только пользователю** (allowlist по Telegram user ID).
- Агент работает 24/7 через systemd (переживает logout и перезагрузку VPS).
- Security audit проходит без critical-findings.
- Пользователь знает, как подключиться к dashboard через SSH-туннель.

**Итого:** 8 фаз, ~60 минут на чистом VPS при нормальном ходе.

---

## 🛡️ Safety principles (для AI)

Перед началом и на протяжении всей установки:

1. **Целевой VPS — только тот, который пользователь явно указал.** Никогда не подключаться к другим серверам, даже если пользователь упомянул второй адрес.
2. **Никаких команд вне `scripts/`** без явного согласования с пользователем. Если нужно сделать что-то, чего нет в скрипте — **остановись и спроси**.
3. **Секреты не выводи в чат.** Если пользователь диктует токен/пароль — подтверди «получил», но не повторяй значение. В логах маскируй `****`.
4. **Destructive-действия** (удаление пользователей, drop таблиц, rm -rf) — **требуют подтверждения пользователя** каждый раз, даже если кажется что это «часть процесса».
5. **Не продолжай при failure.** Если фаза не прошла success criteria — остановись, сообщи пользователю, предложи диагностику. Не переходи к следующей фазе.
6. **Документируй каждый шаг.** Веди краткий лог: `[Phase X] действие → результат`. Это будет показано пользователю в финальном отчёте.

---

## Phase 0 — Preflight (проверка готовности)

**Цель:** убедиться что у пользователя есть всё необходимое **до** того, как начнём трогать сервер.

### Входные данные, которые AI должен запросить

Через диалог, по одному вопросу за раз:

1. **IP-адрес VPS** (формат: `XXX.XXX.XXX.XXX`).
2. **Пароль root** (или SSH-ключ, если пользователь уже настроил ключ).
3. **Порт SSH** (по умолчанию 22, но некоторые провайдеры дают нестандартный — смотри письмо при создании VPS).
4. **Провайдер VPS** (опционально, для провайдер-специфичных нюансов — напр. Hetzner требует верификацию, Timeweb/Beget/aeza дают СБП, Hostinger — one-click marketplace). Работаем с любым провайдером, который даёт Ubuntu 22.04+ или Debian 12.
5. **ОС** (`Ubuntu 22.04` / `Ubuntu 24.04` / `Debian 12`) — если не указано, проверим сами после SSH.
6. **Подтверждение наличия ChatGPT Plus или Pro подписки** (yes/no).
7. **Подтверждение рабочего VPN** для следующего этапа OAuth (yes/no).
8. **Подтверждение активного Telegram-аккаунта** (yes/no).
9. **Текстовое согласие** с тем, что AI получит SSH-доступ к указанному серверу и будет его администрировать.

### Действия AI

- Валидировать формат IP (регэксп).
- Валидировать что пользователь подтвердил все 3 yes/no (ChatGPT, VPN, Telegram).
- Если что-то не подтверждено — **остановить процесс** и объяснить, что нужно получить.

### Success criteria

- Все 9 входных данных получены.
- Пользователь подтвердил согласие на SSH-администрирование.

### Failure recovery

- Нет ChatGPT Plus/Pro → предложить альтернативы (DeepSeek через API-ключ, OpenRouter). Если пользователь выбирает альтернативу — переключиться на соответствующий вариант в Phase 4.
- Нет VPN → остановить. «VPN нужен на этапе OAuth к ChatGPT. Без него не можем продолжать.»
- Сомнения в безопасности → дать ссылку на `docs/architecture.md` («что именно делает AI»).

---

## Phase 1 — First SSH + baseline check

**Цель:** подключиться к серверу, сменить дефолтный пароль root, убедиться что ОС ok.

### Действия AI

1. Подключиться по SSH к `root@<IP>:<PORT>` с указанным паролем.
   ```bash
   ssh root@<IP> -p <PORT>
   ```
2. При первом входе некоторые провайдеры могут попросить сменить пароль — выполнить (новый пароль пользователь выбирает или генерирует AI).
3. Проверить ОС:
   ```bash
   cat /etc/os-release
   uname -a
   ```
4. Проверить доступ к интернету с сервера:
   ```bash
   curl -fsSI https://openclaw.ai/install.sh | head -1
   ```
5. Проверить свободное место и RAM:
   ```bash
   df -h /
   free -h
   ```

### Success criteria

- SSH установился, получен prompt root shell.
- ОС — Ubuntu 22.04 или 24.04 (или Debian 12; если что-то другое — остановиться).
- Доступ к интернету работает.
- Свободного диска > 5 ГБ, RAM > 1.5 ГБ.

### Failure recovery

- SSH не подключается → проверить IP, порт, пароль. Попросить пользователя подтвердить данные.
- ОС не Ubuntu/Debian → остановиться. «Установщик поддерживает только Ubuntu 22.04+, Debian 12. Другие ОС — через ручной путь из Notion-гайда.»
- Нет интернета → проверить DNS и firewall провайдера, предложить связаться с support-чатом провайдера.

---

## Phase 2 — Security hardening (base)

**Цель:** настроить базовую безопасность **до** установки OpenClaw. Мы не хотим ставить критичный сервис на уязвимый сервер.

### Действия AI

Запустить `scripts/ssh-harden.sh` со следующими параметрами:

```bash
bash scripts/ssh-harden.sh \
  --username openclaw \
  --allow-ssh-port 22 \
  --install-fail2ban yes
```

Что делает скрипт (см. `scripts/ssh-harden.sh`):

1. **Создаёт non-root пользователя `openclaw`** с sudo-правами.
2. **Генерирует SSH-ключ** на сервере (или принимает публичный ключ пользователя, если передан).
3. **Копирует `authorized_keys`** с root на `openclaw`.
4. **Меняет SSH-конфиг:** `PasswordAuthentication no`, `PermitRootLogin no`.
5. **Устанавливает и включает UFW:**
   - `deny incoming` по умолчанию.
   - `allow 22/tcp` (SSH).
6. **Устанавливает и включает fail2ban** с дефолтной конфигурацией.
7. **Рестарт sshd, проверка что UFW активен.**

### Критичный момент: SSH-ключи

После этой фазы **пароль для SSH не работает**. Пользователь может подключиться **только через SSH-ключ**.

AI **обязательно**:

- Убедиться что приватный ключ в безопасности у пользователя (у AI его нет).
- Если пользователь даёт свой публичный ключ — верифицировать формат.
- Если пользователь просит сгенерировать новый ключ — **показать** приватный ключ один раз и попросить его сохранить в `~/.ssh/openclaw_vps` на локальной машине. Потом удалить приватный ключ с сервера.

### Success criteria

- Пользователь `openclaw` существует, может sudo.
- SSH по паролю выключен, root login выключен.
- UFW активен, в статусе показывает `allow 22/tcp`.
- fail2ban в статусе `active (running)`.

### Failure recovery

- Ошибка при смене SSH-конфига → откатить к исходному, **не** рестартить sshd пока не проверено.
- UFW заблокировал SSH → у большинства провайдеров есть web-консоль (VNC/rescue mode) в панели управления, через неё снять блок.
- Не генерируется ключ → попросить пользователя сгенерировать локально (`ssh-keygen -t ed25519`) и передать публичный ключ.

### Контрольная точка

**Пользователь подтверждает,** что может подключиться к серверу через нового пользователя:

```bash
ssh openclaw@<IP>
```

Пока это не подтверждено — **не продолжать** (чтобы не потерять доступ к серверу).

---

## Phase 3 — Install OpenClaw

**Цель:** установить OpenClaw и настроить его как systemd-сервис.

### Действия AI

Запустить `scripts/install-openclaw.sh` под пользователем `openclaw`:

```bash
ssh openclaw@<IP>
bash scripts/install-openclaw.sh
```

Что делает скрипт:

1. Устанавливает **Node.js 22** (через NodeSource или через `install.sh` OpenClaw).
2. Выполняет `curl -fsSL https://openclaw.ai/install.sh | bash`.
3. Проверяет установку: `openclaw --version`.
4. Выполняет `openclaw doctor` (без фиксов).
5. Фиксирует путь до бинаря (обычно `/home/openclaw/.npm-global/bin/openclaw` или `~/.openclaw/bin/openclaw`).

### Success criteria

- `openclaw --version` показывает `v2026.X.Y` (любую стабильную ≥ `v2026.1.29`).
- `openclaw doctor` либо показывает `ok`, либо показывает warnings без critical.
- Бинарь `openclaw` доступен в PATH для пользователя `openclaw`.

### Failure recovery

- Версия < 2026.1.29 → **критичный стоп** (CVE-2026-25253). Обновить до stable.
- `openclaw doctor` показывает critical → запустить `openclaw doctor --repair` (не `--force`!), проверить снова.
- Нет Node → скрипт не должен был дойти до этого шага. Вернуться к phase 2.

---

## Phase 4 — Onboard без каналов и LLM (минимальный baseline)

**Цель:** инициализировать OpenClaw, установить systemd daemon, сгенерировать gateway-токен. Без подключения LLM и мессенджера (это следующие фазы).

### Действия AI

```bash
openclaw onboard --non-interactive \
  --mode local \
  --auth-choice skip \
  --skip-search \
  --skip-skills \
  --install-daemon \
  --daemon-runtime node \
  --gateway-bind 127.0.0.1 \
  --gateway-port 18789 \
  --gateway-auth token
```

Затем сгенерировать токен:

```bash
openclaw doctor --generate-gateway-token
```

Проверить systemd unit:

```bash
systemctl --user status openclaw-gateway
```

### Success criteria

- `openclaw onboard` отработал без ошибок.
- Сгенерирован gateway-токен (виден через `openclaw config get gateway.auth.token`).
- systemd user unit активен: `systemctl --user status openclaw-gateway` показывает `active (running)`.
- `openclaw gateway status` показывает `reachable`.
- `loginctl enable-linger openclaw` выполнено (это делает `--install-daemon` автоматически).

### Failure recovery

- onboard падает с неизвестной ошибкой → `openclaw doctor --deep --non-interactive`, анализ вывода.
- systemd unit не запускается → `journalctl --user -u openclaw-gateway --no-pager -n 100`, анализ логов.
- Если linger не включился → `sudo loginctl enable-linger openclaw` вручную.

---

## Phase 5 — Подключение ChatGPT Plus/Pro (Codex OAuth)

**Цель:** привязать подписку ChatGPT пользователя как LLM-бэкенд.

### ⚠️ Критичная зона: нужен VPN

На этом этапе происходит OAuth-редирект на `auth.openai.com`, который заблокирован в России. Пользователю **нужен рабочий VPN** для этого единственного шага.

### Действия AI

1. **Попросить пользователя включить VPN** и подтвердить.
2. На сервере запустить OAuth:
   ```bash
   openclaw models auth login --provider openai-codex
   ```
3. Скрипт выдаст URL — **передать его пользователю** с инструкцией:
   - «Открой этот URL в браузере с включённым VPN.»
   - «Залогинься в свой ChatGPT-аккаунт.»
   - «После успешного логина браузер покажет страницу с callback-URL вида `http://localhost:...`. Скопируй её целиком и пришли мне.»
4. Пользователь присылает callback-URL → AI вставляет в CLI.
5. OAuth завершается.

### Задать primary model

```bash
openclaw config set agents.defaults.model.primary openai-codex/gpt-5.4
openclaw gateway restart
```

### Success criteria

- `openclaw models status` показывает `openai-codex/gpt-5.4` как `authenticated` и `healthy`.
- `openclaw config get agents.defaults.model.primary` возвращает `openai-codex/gpt-5.4`.
- `openclaw gateway status` показывает `reachable`.

### Failure recovery

- Callback-URL невалидный → попросить пользователя прислать URL целиком, включая query-parameters.
- `openclaw models status` показывает auth error → повторить `openclaw models auth login`.
- Пользователь не может открыть `auth.openai.com` даже с VPN → проверить VPN-сервер (некоторые VPN-сервисы забанены OpenAI; попробовать другую страну/другой сервис).
- У пользователя нет подписки Plus/Pro → переключить на альтернативу (DeepSeek):
  ```bash
  openclaw models auth add --provider deepseek
  openclaw config set agents.defaults.model.primary deepseek/deepseek-chat
  ```
  И в остальной инструкции использовать `deepseek/deepseek-chat` вместо `openai-codex/gpt-5.4`.

### Важно: пользователь может отключить VPN

После успешного OAuth VPN **можно выключать**. API-endpoint OpenAI (для OpenClaw-запросов) исторически доступен из России без VPN. OAuth-редирект был one-time событием.

---

## Phase 6 — Создание Telegram-бота

**Цель:** получить токен бота через @BotFather.

### Действия пользователя (AI даёт инструкции)

1. Открыть в Telegram чат с `@BotFather` (убедиться что handle именно `@BotFather`, без опечатки).
2. Отправить `/newbot`.
3. На запрос имени — ввести любое отображаемое имя (например, «Мой ассистент»).
4. На запрос username — ввести уникальное имя с суффиксом `bot` (например, `max_assistant_bot`).
5. BotFather пришлёт сообщение с **HTTP API токеном** вида `1234567890:AAHabcdef...`.
6. **Скопировать токен** и отправить его AI в чате Claude Code / Codex.

### Действия AI после получения токена

1. Маскировать токен в логах (`****`).
2. Сохранить токен в переменную окружения:
   ```bash
   echo 'TELEGRAM_BOT_TOKEN="<token>"' | sudo tee /etc/openclaw/env > /dev/null
   sudo chmod 600 /etc/openclaw/env
   sudo chown openclaw:openclaw /etc/openclaw/env
   ```
3. Прописать в конфиг OpenClaw:
   ```bash
   openclaw config set channels.telegram.enabled true
   openclaw config set channels.telegram.botToken '${TELEGRAM_BOT_TOKEN}'
   openclaw config set channels.telegram.dmPolicy pairing
   ```
4. Перезапустить gateway:
   ```bash
   openclaw gateway restart
   openclaw gateway status
   ```

### Success criteria

- Токен получен от BotFather и сохранён на сервере.
- `openclaw config get channels.telegram.enabled` возвращает `true`.
- `openclaw channels status telegram` показывает `healthy`.

### Failure recovery

- BotFather возвращает ошибку при создании → username занят, попросить другой.
- Токен невалидный → пользователь, вероятно, неправильно скопировал. Попросить ещё раз целиком.
- `channels status` показывает `unreachable` → проверить `api.telegram.org` доступен с сервера (`curl -I https://api.telegram.org`). Если нет — VPN / прокси для сервера.

---

## Phase 7 — Pairing (связать Telegram-аккаунт с агентом)

**Цель:** авторизовать конкретный Telegram-аккаунт пользователя как владельца бота.

### Действия пользователя

1. Открыть своего бота в Telegram (по ссылке `t.me/<bot_username>` или просто найти по имени).
2. Отправить `/start`.
3. Бот ответит: «Для авторизации выполни на сервере эту команду: `openclaw pairing approve telegram <CODE>`» — с конкретным кодом.
4. **Скопировать команду** с кодом и отправить AI.

### Действия AI

1. Выполнить команду на сервере (как пользователь `openclaw`):
   ```bash
   openclaw pairing approve telegram <CODE>
   ```
2. Проверить:
   ```bash
   openclaw channels status telegram
   openclaw pairing list telegram
   ```

### Success criteria

- `pairing approve` вернул success.
- `pairing list` показывает пользователя как approved.
- Пользователь отправляет `Привет` боту → получает ответ от агента.

### Failure recovery

- Код истёк (pairing-коды живут 1 час) → пользователь делает `/start` ещё раз, получает новый код.
- Бот не отвечает → проверить `openclaw gateway status`, `journalctl --user -u openclaw-gateway -n 50`.
- Pairing прошёл, но бот отвечает generic-сообщением → проверить что primary model активна: `openclaw models status`.

---

## Phase 8 — Telegram allowlist (только ты пишешь боту)

**Цель:** бот отвечает **только пользователю**, игнорирует чужих.

### Действия AI

1. Получить Telegram user ID пользователя:
   ```bash
   openclaw logs --follow
   ```
   Пока пользователь пишет боту, смотреть строку `from.id: 123456789`.
2. Или попросить пользователя использовать `@userinfobot` в Telegram — бот вернёт user ID.
3. Прописать в конфиг:
   ```bash
   openclaw config set channels.telegram.dmPolicy allowlist
   openclaw config set channels.telegram.allowFrom '["<USER_ID>"]'
   openclaw config set channels.telegram.groupPolicy disabled
   openclaw gateway restart
   ```

### Success criteria

- `dmPolicy: "allowlist"`, `allowFrom: [<user_id>]`.
- Пользователь пишет боту — получает ответ.
- (Тест опционально) Другой Telegram-аккаунт пишет боту — игнорируется.

### Failure recovery

- Невозможно найти user ID в логах → попросить через @userinfobot.
- После allowlist сам пользователь игнорируется → user ID неправильный, проверить.

---

## Phase 9 — Security hardening конфига + audit

**Цель:** закрыть небезопасные дефолты OpenClaw и запустить полный audit.

### Действия AI

1. Переопределить небезопасные дефолты:
   ```bash
   openclaw config set agents.defaults.sandbox.mode all
   openclaw config set agents.defaults.elevatedDefault ask
   openclaw config set tools.elevated.enabled false
   openclaw config set tools.profile coding
   ```
2. Включить полезные hooks:
   ```bash
   openclaw hooks enable command-logger
   openclaw hooks enable session-memory
   ```
3. Перезапустить gateway:
   ```bash
   openclaw gateway restart
   ```
4. Запустить security audit:
   ```bash
   openclaw security audit --deep > /tmp/audit.log
   cat /tmp/audit.log
   ```
5. Проанализировать вывод audit'а:
   - **Critical issues** — исправить через `openclaw security audit --fix` или вручную.
   - **Warnings** — оценить, предложить пользователю решение.
   - **Info** — проигнорировать.

### Success criteria

- `sandbox.mode = "all"`, `elevated.enabled = false`.
- `command-logger` и `session-memory` включены.
- `security audit --deep` не показывает critical.
- Gateway работает.

### Failure recovery

- `sandbox.mode: "all"` ломает работу агента → снизить до `non-main` (компромисс).
- Critical findings не исправляются автоматически → показать пользователю, объяснить, предложить ручной fix.

---

## Phase 10 — Handoff пользователю

**Цель:** завершить установку, объяснить пользователю, как пользоваться дальше.

### Действия AI

Сформировать **финальный отчёт** пользователю:

```markdown
✅ Установка завершена успешно.

**Что работает:**
- Бот в Telegram: @<bot_username>
- LLM: openai-codex/gpt-5.4 (через твою подписку ChatGPT Plus/Pro)
- Агент запущен как systemd-сервис, переживает logout и перезагрузки.
- Security audit: без critical findings.
- Бот отвечает только тебе (Telegram ID <USER_ID>).

**Что попробовать:**
1. Напиши боту «Привет, расскажи о себе» — должен представиться.
2. Напиши «Какой сегодня день недели?» — проверит access к datetime.
3. Напиши что-нибудь сложное — протестируй качество модели.

**Как подключиться к веб-дашборду:**
На локальной машине:
  ssh -N -L 18789:127.0.0.1:18789 openclaw@<IP>
Затем открыть http://127.0.0.1:18789 в браузере.

**Как мониторить:**
  ssh openclaw@<IP>
  openclaw gateway status
  openclaw logs --follow
  journalctl --user -u openclaw-gateway --no-pager -n 50

**Обновление:**
  ssh openclaw@<IP>
  npm install -g openclaw@latest
  openclaw doctor --deep
  openclaw gateway restart
  openclaw security audit --deep

**Если что-то пойдёт не так:**
- Troubleshooting: `docs/troubleshooting.md` в этом репо.
- Полный гайд: [Notion-ссылка].

**Чего мы НЕ делали (оставь на потом):**
- SOUL.md (личность агента) — агент работает с дефолтными настройками. Чтобы дать ему имя, характер, специализацию — читай `templates/soul/`.
- Скилы (Gmail, Google Calendar, веб-поиск) — добавь их через `openclaw skills install`.
- Nginx reverse-proxy + TLS — только если хочешь доступ к dashboard с телефона без SSH-туннеля.

**Спасибо за установку. Если всё работает — поделись результатом в AI Room Club.**
```

### Success criteria

- Пользователь подтвердил, что бот отвечает.
- Пользователь знает, как подключиться к dashboard и обновлять OpenClaw.
- Все credentials в безопасности у пользователя (SSH-ключ, Telegram-токен, gateway-токен).

---

## 📋 Итоговый чек-лист для AI

Перед тем как отчитаться пользователю — пройти своим внутренним чек-листом:

- [ ] Phase 0: preflight прошёл, все данные получены, согласие дано.
- [ ] Phase 1: SSH работает, ОС Ubuntu/Debian.
- [ ] Phase 2: non-root user, SSH-keys, UFW, fail2ban — всё активно.
- [ ] Phase 3: OpenClaw версии ≥ v2026.1.29.
- [ ] Phase 4: systemd unit активен, gateway reachable.
- [ ] Phase 5: primary model = openai-codex/gpt-5.4 (или альтернатива).
- [ ] Phase 6: Telegram-канал подключён, status healthy.
- [ ] Phase 7: pairing approved.
- [ ] Phase 8: dmPolicy = allowlist, allowFrom настроен.
- [ ] Phase 9: sandbox.mode = all, elevated = false, audit без critical.
- [ ] Phase 10: handoff пользователю, все данные переданы.

---

## 🔄 Что делать, если всё сломалось на середине

1. **Не паниковать.** OpenClaw можно переустановить.
2. **Сохранить логи** в `~/openclaw-install.log` (AI их пишет по ходу).
3. **Откат:**
   ```bash
   openclaw uninstall
   # или полный ребилд VPS через панель твоего провайдера (snapshot не требуется — установщик быстрый)
   ```
4. **Запустить установщик заново.** Preflight пропустит некоторые шаги, если они уже сделаны (идемпотентность).
5. **Если одна и та же фаза падает второй раз** — зафиксировать лог, открыть issue в этом репо.

---

## Ссылки на внешние ресурсы

- [Официальная документация OpenClaw](https://docs.openclaw.ai)
- [CLI-справочник OpenClaw](https://docs.openclaw.ai/cli/index.md)
- [Providers & models](https://docs.openclaw.ai/providers/openai.md)
- [Security guide](https://docs.openclaw.ai/gateway/security)
- [GitHub репозиторий OpenClaw](https://github.com/openclaw/openclaw)
- [AI Room Club](https://airoomclub.ru) — сообщество, которое сделало этот установщик
