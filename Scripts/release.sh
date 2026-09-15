#!/usr/bin/env bash
# Выпускает версию: VERSION → коммит → тег vX.Y.Z → push.
# Собирает и публикует DMG и архив GitHub Actions (.github/workflows/release.yml).
# Использование: Scripts/release.sh 1.2.0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NEW="${1:-}"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "укажите версию вида 1.2.0"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "есть незакоммиченные изменения — сначала закоммитьте их"; exit 1; }
if git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null; then
    echo "тег v$NEW уже существует"
    exit 1
fi

CURRENT="$(tr -d '[:space:]' < VERSION)"
if [ "$CURRENT" != "$NEW" ]; then
    HIGHEST="$(printf '%s\n%s\n' "$CURRENT" "$NEW" | sort -V | tail -1)"
    [ "$HIGHEST" = "$NEW" ] || { echo "версия $NEW меньше текущей $CURRENT"; exit 1; }
    echo "$NEW" > VERSION
    git add VERSION
    git commit -m "chore: версия $NEW"
fi

git tag -a "v$NEW" -m "Steno $NEW"
git push origin HEAD
git push origin "v$NEW"

echo "тег v$NEW отправлен. Ход сборки: gh run watch"
