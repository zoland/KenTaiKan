#!/usr/bin/env bash
set -euo pipefail

# =========================
# GitHub deploy with asset fingerprinting and push fallbacks
# =========================
# Usage:
#   ./deploy.sh ["COMMIT MESSAGE"] [BRANCH]
#
# Defaults:
#   COMMIT MESSAGE = Deploy: <UTC timestamp>
#   BRANCH = main
#
# Notes:
# - Фингерпринтит assets/styles.css и assets/script.js → добавляет хэш в имя,
#   и переписывает ссылки в index.html и pages/*.html.
# - Пуш: origin (SSH:22) → ssh://git@ssh.github.com:443/... → HTTPS.
#   Для HTTPS выставьте GITHUB_TOKEN (repo:write) или используйте origin на https.

COMMIT_MSG="${1:-Deploy: $(date -u '+%Y-%m-%d %H:%M:%S UTC')}"
BRANCH="${2:-main}"

info()  { printf "\033[1;34m[info]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[err ]\033[0m %s\n" "$*" >&2; }
have()  { command -v "$1" >/dev/null 2>&1; }

# -------- sanity checks --------
if [[ ! -f "index.html" ]]; then
  error "Не найден index.html. Запустите из корня проекта."
  exit 1
fi
if ! have git; then
  error "Не найден git. Установите и повторите."
  exit 1
fi

# -------- git init/branch --------
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

# -------- basic files --------
[[ -f ".nojekyll" ]] || { info "Создаю .nojekyll"; touch .nojekyll; }
if [[ ! -f ".gitignore" ]]; then
  info "Создаю .gitignore"
  cat > .gitignore <<'EOF'
.DS_Store
Thumbs.db
*.log
node_modules/
dist/
.cache/
assets/styles.*.css
assets/script.*.js
EOF
fi

# -------- detect origin / owner/repo --------
default_origin="git@github.com:zoland/KenTaiKan.git"
if ! git remote get-url origin >/dev/null 2>&1; then
  warn "origin не настроен. Добавляю: $default_origin"
  git remote add origin "$default_origin"
fi
ORIGIN_URL="$(git remote get-url origin)"

owner_repo_from_url() {
  local url="$1"
  local s
  s="$(echo "$url" | sed -E \
    -e 's#^git@[^:]+:##' \
    -e 's#^ssh://git@[^/]+[:/]+##' \
    -e 's#^https?://[^/]+/##')"
  s="${s%.git}"
  echo "$s"
}
OWNER_REPO="$(owner_repo_from_url "$ORIGIN_URL")"
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"
SSH_22_URL="git@github.com:${OWNER}/${REPO}.git"
SSH_443_URL="ssh://git@ssh.github.com:443/${OWNER}/${REPO}.git"
HTTPS_URL="https://github.com/${OWNER}/${REPO}.git"

# -------- fingerprint helpers --------
hash_file() {
  local f="$1"
  if have shasum; then
    shasum -a 256 "$f" | awk '{print substr($1,1,10)}'
  elif have md5; then
    md5 -q "$f" | awk '{print substr($1,1,10)}'
  else
    date +%s
  fi
}

replace_in_file() {
  # macOS-compatible sed -i
  local file="$1"
  local search="$2"
  local replace="$3"
  sed -i '' -E "s#${search}#${replace}#g" "$file"
}

fingerprint_asset() {
  # Args: src_path base_name ext html_path_prefix
  local SRC="$1"      # e.g., assets/styles.css
  local BASE="$2"     # e.g., styles
  local EXT="$3"      # e.g., css
  local HASH
  [[ -f "$SRC" ]] || return 0

  HASH="$(hash_file "$SRC")"
  local DST="assets/${BASE}.${HASH}.${EXT}"
  cp "$SRC" "$DST"
  info "Фингерпринт: $SRC → $DST"

  # В корневом index.html:
  if [[ -f "index.html" ]]; then
    # Сначала любые прошлые hashed-версии → новая
    replace_in_file "index.html" "assets/${BASE}\.[A-Za-z0-9]+\.${EXT}" "assets/${BASE}.${HASH}.${EXT}"
    # Затем голое имя → новая
    replace_in_file "index.html" "assets/${BASE}\.${EXT}" "assets/${BASE}.${HASH}.${EXT}"
  fi

  # Во внутренних страницах
  if ls pages/*.html >/dev/null 2>&1; then
    for f in pages/*.html; do
      replace_in_file "$f" "\.\./assets/${BASE}\.[A-Za-z0-9]+\.${EXT}" "../assets/${BASE}.${HASH}.${EXT}"
      replace_in_file "$f" "\.\./assets/${BASE}\.${EXT}" "../assets/${BASE}.${HASH}.${EXT}"
    done
  fi

  # Чистим старые версии (оставим 3 свежих)
  local keep=3
  local list
  list=$(ls -t "assets/${BASE}."*".${EXT}" 2>/dev/null || true)
  if [[ -n "$list" ]]; then
    echo "$list" | awk "NR>${keep}" | xargs -I {} rm -f "{}" 2>/dev/null || true
  fi
}

# -------- fingerprint run --------
info "Готовлю кэш-банг без ?v= — фингерпринт ассетов..."
fingerprint_asset "assets/styles.css" "styles" "css"
fingerprint_asset "assets/script.js"  "script" "js"

# -------- git add/commit --------
info "Индексируем изменения..."
git add -A

if git diff --cached --quiet && git diff --quiet; then
  info "Нет изменений для коммита."
else
  info "Создаю коммит: $COMMIT_MSG"
  git commit -m "$COMMIT_MSG"
fi

# -------- push fallbacks --------
try_push_origin() {
  info "Публикую в origin ($BRANCH) по SSH:22..."
  set +e; git push -u origin "$BRANCH"; rc=$?; set -e; return $rc
}
try_push_ssh443() {
  warn "Пробую SSH через порт 443..."
  set +e; git push -u "$SSH_443_URL" "$BRANCH"; rc=$?; set -e; return $rc
}
try_push_https() {
  warn "Пробую HTTPS..."
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    set +e
    git push -u "https://${GITHUB_TOKEN}@github.com/${OWNER}/${REPO}.git" "$BRANCH"
    rc=$?
    set -e
    return $rc
  fi
  error "GITHUB_TOKEN не задан. Экспортируйте токен или смените origin на https."
  printf "Пример:\n  export GITHUB_TOKEN=ghp_xxx\n  ./deploy.sh\n"
  return 99
}

pushed_via=""
if try_push_origin; then
  pushed_via="ssh22"
else
  warn "SSH:22 недоступен. Переключаюсь на fallback..."
  if try_push_ssh443; then
    pushed_via="ssh443"
  else
    warn "SSH:443 не удался. Пробую HTTPS..."
    if try_push_https; then
      pushed_via="https"
    else
      rc=$?
      [[ $rc -eq 99 ]] && exit 1
      error "Push по HTTPS не удался (код $rc)."
      exit $rc
    fi
  fi
fi

case "$pushed_via" in
  ssh443)
    warn "Закрепить SSH:443 в origin на постоянной основе? (y/N)"
    read -r ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      git remote set-url origin "$SSH_443_URL"
      info "origin → $SSH_443_URL"
    fi
    ;;
  https)
    warn "Переключить origin на HTTPS? (y/N)"
    read -r ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      git remote set-url origin "$HTTPS_URL"
      info "origin → $HTTPS_URL"
    fi
    ;;
esac

info "Готово. Проверьте сайт через 1–3 минуты:
  https://${OWNER}.github.io/${REPO}/"