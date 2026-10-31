#!/usr/bin/env bash
# お知らせ用のアカウント(bot)で投稿する
#
#   TOKEN=<アクセストークン> felesitas/announce.sh <ドメイン> <更新前の版>
#     版が上がっていれば「v〜にアップデートしました」を公開で投稿する
#   TOKEN=<アクセストークン> TEXT=<文面> [VISIBILITY=unlisted] felesitas/announce.sh <ドメイン>
#     TEXT をそのまま投稿する(試し用)
# トークンは write:statuses だけを許したもの。

set -euo pipefail

DOMAIN="$1"
BEFORE="${2:-}"
VISIBILITY="${VISIBILITY:-public}"

if [[ -z "${TOKEN:-}" ]]; then
  echo "トークンが無いので投稿しません"
  exit 0
fi

if [[ -z "${TEXT:-}" ]]; then
  AFTER="$(curl -fsS "https://$DOMAIN/api/v2/instance" | jq -r .version)"
  echo "前: $BEFORE / 後: $AFTER"
  if [[ -z "$AFTER" || "$AFTER" == "$BEFORE" ]]; then
    echo "版は変わっていないので投稿しません"
    exit 0
  fi
  TEXT="$DOMAIN を Mastodon v$AFTER にアップデートしました。"$'\n\n'"公式の変更点: https://github.com/mastodon/mastodon/releases/tag/v$AFTER"
  KEY="felesitas-update-$DOMAIN-$AFTER"
else
  KEY="felesitas-test-$(date +%s)-$RANDOM"
fi

curl -fsS -o /dev/null -w '投稿しました(HTTP %{http_code})\n' -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: $KEY" \
  --data-urlencode "status=$TEXT" \
  --data-urlencode "visibility=$VISIBILITY" \
  "https://$DOMAIN/api/v1/statuses"
