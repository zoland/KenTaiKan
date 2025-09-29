#!/usr/bin/env bash
set -euo pipefail

# Простая публикация: коммит без пуша. Пушите через GitHub Desktop.
COMMIT_MSG="${1:-Site update: $(date '+%Y-%m-%d %H:%M')}"
BRANCH="${2:-main}"

echo "[info] Проверяю наличие ключевых файлов..."
missing=0
for f in index.html assets/styles.css; do
  if [[ ! -f "$f" ]]; then
    echo "[warn] Не найден $f"
    missing=1
  fi
done
if [[ -d pages ]]; then
  echo "[info] Обнаружена папка pages/"
fi

echo "[info] Индексирую изменения..."
git add -A

if git diff --cached --quiet; then
  echo "[info] Нет изменений для коммита."
else
  echo "[info] Создаю коммит: $COMMIT_MSG"
  git commit -m "$COMMIT_MSG"
fi

echo ""
echo "[ok] Готово. Откройте GitHub Desktop и нажмите Push."
echo "     В браузере после публикации сделайте жёсткое обновление (Cmd+Shift+R)."