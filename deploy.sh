#!/usr/bin/env bash
set -euo pipefail

# =========================
# GitHub deploy with fallbacks (SSH → SSH:443 → HTTPS)
# =========================
# Usage:
#   ./deploy.sh [REPO_URL] ["COMMIT MESSAGE"] [BRANCH]
#
# Defaults:
#   REPO_URL = git@github.com:zoland/KenTaiKan.git
#   COMMIT MESSAGE = Deploy: <UTC timestamp>
#   BRANCH = main
#
# Fallbacks:
#   1) git push -u origin <branch>                        (SSH :22)
#   2) git push -u ssh://git@ssh.github.com:443/O/R.git   (SSH :443)
#   3) git push -u https://github.com/O/R.git             (HTTPS, c gh)
#      либо git push -u https://TOKEN@github.com/O/R.git  (HTTPS, с GITHUB_TOKEN)
#
# Примечания:
# - Для HTTPS рекомендуются: gh auth login (CLI) или переменная окружения GITHUB_TOKEN (fine-grained).
# - Скрипт не хранит токен в origin — пушит по одноразовому URL.
# - После успешного пуша через fallback предложит обновить origin.

REPO_URL="${1:-git@github.com:zoland/KenTaiKan.git}"
COMMIT_MSG="${2:-Deploy: $(date -u '+%Y-%m-%d %H:%M:%S UTC')}"
BRANCH="${3:-main}"

info()  { printf "\033[1;34m[info]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[err ]\033[0m %s\n" "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- sanity checks ---
if [[ ! -f "index.html" ]]; then
  error "Не найден index.html. Запустите из корня проекта."
  exit 1
fi
if ! have git; then
  error "Не найден git. Установите и повторите."
  exit 1
fi

# --- helpers ---

# Извлекаем OWNER/REPO из адреса (поддержка SSH/SSH:443/HTTPS)
owner_repo_from_url() {
  local url="$1"
  # Убираем схемы/хосты, оставляем owner/repo(.git)
  local s
  s="$(echo "$url" | sed -E \
    -e 's#^git@[^:]+:##' \
    -e 's#^ssh://git@[^/]+[:/]+##' \
    -e 's#^https?://[^/]+/##')"
  s="${s%.git}"
  echo "$s"
}

OWNER_REPO="$(owner_repo_from_url "$REPO_URL")"
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"

if [[ -z "$OWNER" || -z "$REPO" || "$OWNER" = "$REPO" ]]; then
  warn "Не удалось корректно разобрать OWNER/REPO из '$REPO_URL'. Проверьте аргумент."
fi

SSH_DEFAULT_URL="git@github.com:${OWNER}/${REPO}.git"
SSH_443_URL="ssh://git@ssh.github.com:443/${OWNER}/${REPO}.git"
HTTPS_URL="https://github.com/${OWNER}/${REPO}.git"

# --- init repo / branch ---
if [[ ! -d ".git" ]]; then
  info "Инициализация нового git-репозитория..."
  git init
  git checkout -b "$BRANCH" >/dev/null 2>&1 || git branch -M "$BRANCH"
else
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    info "Переключение/переименование ветки на $BRANCH..."
    git branch -M "$BRANCH"
  fi
fi

# Локальная конфигурация (по желанию)
if ! git config user.name >/dev/null; then
  warn "git user.name не задан. Указать сейчас? (y/N)"
  read -r ans
  if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
    read -r -p "Введите user.name: " uname
    git config user.name "$uname"
  fi
fi
if ! git config user.email >/dev/null; then
  warn "git user.email не задан. Указать сейчас? (y/N)"
  read -r ans
  if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
    read -r -p "Введите user.email: " uemail
    git config user.email "$uemail"
  fi
fi

# Базовые служебные файлы
[[ -f ".nojekyll" ]] || { info "Создаю .nojekyll"; touch .nojekyll; }
if [[ ! -f ".gitignore" ]]; then
  info "Создаю .gitignore"
  cat > .gitignore <<'EOF'
# OS/editor
.DS_Store
Thumbs.db
*.log

# Tooling
node_modules/
dist/
.cache/
EOF
fi

# Настраиваем origin (если его ещё нет)
if ! git remote get-url origin >/dev/null 2>&1; then
  info "Добавляю origin: $SSH_DEFAULT_URL"
  git remote add origin "$SSH_DEFAULT_URL"
fi

# Индексация/коммит
info "Индексируем изменения..."
git add -A
if git diff --cached --quiet && git diff --quiet; then
  info "Нет изменений для коммита."
else
  info "Создаю коммит: $COMMIT_MSG"
  git commit -m "$COMMIT_MSG"
fi

# --- push attempts ---
try_push_origin() {
  info "Публикую в origin ($BRANCH) по SSH:22..."
  set +e
  git push -u origin "$BRANCH"
  rc=$?
  set -e
  return $rc
}
try_push_ssh443() {
  warn "Пробую SSH через порт 443 (без смены origin)..."
  set +e
  git push -u "$SSH_443_URL" "$BRANCH"
  rc=$?
  set -e
  return $rc
}
try_push_https() {
  warn "Пробую HTTPS..."
  # Если есть gh и пользователь авторизован — используем обычный https URL
  if have gh && gh auth status >/dev/null 2>&1; then
    set +e
    git push -u "$HTTPS_URL" "$BRANCH"
    rc=$?
    set -e
    return $rc
  fi
  # Если задан GITHUB_TOKEN — пушим разово по URL с токеном (без смены origin)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    warn "Использую GITHUB_TOKEN из окружения для разового HTTPS-пуша."
    set +e
    git push -u "https://${GITHUB_TOKEN}@github.com/${OWNER}/${REPO}.git" "$BRANCH"
    rc=$?
    set -e
    return $rc
  fi
  # Иначе — подсказка как авторизоваться
  error "Нет gh-авторизации и не задан GITHUB_TOKEN."
  printf "Быстрый вариант (рекомендовано):\n"
  printf "  1) Установить GitHub CLI: brew install gh\n"
  printf "  2) Выполнить: gh auth login  (GitHub.com → HTTPS → Browser)\n"
  printf "  3) Повторно запустить: ./deploy.sh\n"
  return 99
}

# 1) origin (SSH :22)
if try_push_origin; then
  info "Готово: push по SSH (22) успешен."
  pushed_via="ssh22"
else
  warn "Push по SSH (22) не удался. Переключаюсь на fallback..."
  # 2) SSH:443
  if try_push_ssh443; then
    info "Готово: push по SSH (443) успешен."
    pushed_via="ssh443"
  else
    warn "SSH (443) тоже не удался. Пробуем HTTPS..."
    if try_push_https; then
      info "Готово: push по HTTPS успешен."
      pushed_via="https"
    else
      rc=$?
      if [[ $rc -eq 99 ]]; then
        exit 1
      fi
      error "Push по HTTPS не удался (код $rc). Проверьте соединение/авторизацию и повторите."
      exit $rc
    fi
  fi
fi

# Предложить закрепить успешный способ в origin (по желанию)
case "${pushed_via:-}" in
  ssh443)
    warn "Хотите закрепить SSH:443 в origin на постоянной основе? (y/N)"
    read -r ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      git remote set-url origin "$SSH_443_URL"
      info "origin обновлён → $SSH_443_URL"
    fi
    ;;
  https)
    warn "Хотите переключить origin на HTTPS? (y/N)"
    read -r ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      git remote set-url origin "$HTTPS_URL"
      info "origin обновлён → $HTTPS_URL"
      warn "Если не используете gh, настройте credential helper или используйте gh auth login."
    fi
    ;;
esac

info "Готово!"
printf "\nДальше:\n"
printf " - Включите GitHub Pages (если ещё не включено): Settings → Pages → Deploy from a branch → %s / root\n" "$BRANCH"
printf " - Предпросмотр: https://%s.github.io/%s/\n" "%s" "%s" | xargs printf "   https://%s.github.io/%s/\n" "${OWNER}" "${REPO}"
printf " - Для домена kentaikan.ru добавьте CNAME и A-записи (GitHub Pages IPs)\n"