#!/usr/bin/env bash
# felesitas.cloud のデプロイ(アップデート・独自実装の反映)
#
# 対象のCT(aeronavis / 本番)のrootで動かす。CIからは次の形で流す:
#   ssh root@<host> 'bash -s' -- <ref> < felesitas/deploy.sh
# <ref> はフォークのブランチ名・タグ・コミット(既定: felesitas)。
#
# 手順: 事前チェック → DBバックアップ → checkout → bundle → yarn
#       → db:migrate(post-deploy以外) → assets:precompile → 再起動
#       → db:migrate(post-deploy) → 動作確認
# 途中で失敗したら、止まった場所と戻し方を表示して終わる。

set -Eeuo pipefail

REF="${1:-felesitas}"
FORK_URL="https://github.com/BananaGikoH/felesitascloud.git"
FORK_REPO="BananaGikoH/felesitascloud"
APP_USER="mastodon"
APP_DIR="/home/mastodon/live"
DB_NAME="mastodon_production"
BACKUP_DIR="/root"
BACKUP_KEEP=3

STEP="開始"
PREV_SHA=""
MIGRATED=""
BACKUP_FILE=""

log() { printf '\n==> [%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# mastodonユーザーで、rbenvのPATHを通して ~/live で実行する
as_app() {
  sudo -u "$APP_USER" -i bash -lc \
    "export PATH=\"\$HOME/.rbenv/shims:\$HOME/.rbenv/bin:\$PATH\" RAILS_ENV=production && cd $APP_DIR && $1"
}

on_error() {
  local code=$?
  echo
  echo "!! 失敗しました(終了コード $code)"
  echo "!! 止まった場所: $STEP"
  if [[ -n "$PREV_SHA" ]]; then
    echo
    echo "戻し方(mastodonユーザーで ~/live にて):"
    echo "  git checkout --detach $PREV_SHA"
    echo "  bundle install && yarn install --immutable"
    echo "  RAILS_ENV=production bundle exec rails assets:precompile"
    echo "そのあとrootで:"
    echo "  systemctl restart mastodon-web mastodon-sidekiq ${STREAMING_UNITS:-mastodon-streaming@4000}"
    if [[ -n "$MIGRATED" ]]; then
      echo
      echo "※ db:migrate が走ったあとです。DBも戻す場合はバックアップから:"
      echo "  systemctl stop mastodon-web mastodon-sidekiq ${STREAMING_UNITS:-mastodon-streaming@4000}"
      echo "  sudo -u postgres pg_restore --clean --if-exists -d $DB_NAME $BACKUP_FILE"
    fi
  fi
  exit "$code"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || { echo "rootで実行してください"; exit 1; }

# ---------------------------------------------------------------
STEP="事前チェック: 取得"
log "$STEP ($REF)"
if ! as_app "git remote get-url felesitas" >/dev/null 2>&1; then
  as_app "git remote add felesitas $FORK_URL"
fi
as_app "git fetch --quiet --tags felesitas"
as_app "git fetch --quiet --tags origin" || true

# ブランチ名ならフォーク側を優先して解決する
SHA="$(as_app "git rev-parse --verify --quiet 'felesitas/$REF^{commit}' || git rev-parse --verify '$REF^{commit}'")"
PREV_SHA="$(as_app "git rev-parse HEAD")"
echo "今: $PREV_SHA"
echo "次: $SHA"

STEP="事前チェック: 作業ツリー"
if [[ -n "$(as_app "git status --porcelain --untracked-files=no")" ]]; then
  echo "~/live に手で変えたファイルがあります。先に片付けてください:"
  as_app "git status --short --untracked-files=no"
  exit 1
fi

STEP="事前チェック: Ruby"
RUBY_VER="$(as_app "git show $SHA:.ruby-version" | tr -d '[:space:]')"
if as_app "rbenv versions --bare" | grep -qx "$RUBY_VER"; then
  echo "Ruby $RUBY_VER: あり"
else
  log "Ruby $RUBY_VER を入れます(数分かかります)"
  as_app "git -C ~/.rbenv/plugins/ruby-build pull --quiet"
  as_app "RUBY_CONFIGURE_OPTS=--with-jemalloc rbenv install $RUBY_VER"
fi

STEP="事前チェック: Node.js"
NODE_NEED="$(as_app "git show $SHA:package.json" | grep -A2 '"engines"' | grep -o '"node": *"[^"]*"' | grep -o '[0-9]\+' | head -1)"
NODE_HAVE="$(node -v | sed 's/^v//; s/\..*//')"
if [[ -n "$NODE_NEED" && "$NODE_HAVE" -lt "$NODE_NEED" ]]; then
  echo "Node.js $NODE_NEED 以上が要ります(今は $NODE_HAVE)。NodeSourceのリポジトリを切り替えてから、もう一度実行してください"
  exit 1
fi
echo "Node.js $NODE_HAVE: OK(要件 >=${NODE_NEED:-?})"
corepack enable

STEP="事前チェック: 空き容量"
FREE_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
echo "空き: ${FREE_GB}GB"
(( FREE_GB >= 5 )) || { echo "空きが5GB未満です"; exit 1; }

STREAMING_UNITS="$(systemctl list-units --plain --no-legend 'mastodon-streaming@*' | awk '{print $1}' | tr '\n' ' ')"
STREAMING_UNITS="${STREAMING_UNITS:-mastodon-streaming@4000}"

# ---------------------------------------------------------------
STEP="DBバックアップ"
log "$STEP"
LABEL="$(as_app "git describe --tags --always $SHA" | tr '/' '-')"
BACKUP_FILE="$BACKUP_DIR/mastodon-before-$LABEL-$(date +%Y%m%d%H%M).dump"
sudo -u postgres pg_dump -Fc -f "/tmp/$(basename "$BACKUP_FILE")" "$DB_NAME"
mv "/tmp/$(basename "$BACKUP_FILE")" "$BACKUP_FILE"
ls -lh "$BACKUP_FILE"
# 古いものは BACKUP_KEEP 個だけ残す
ls -1t "$BACKUP_DIR"/mastodon-before-*.dump 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -v

# ---------------------------------------------------------------
STEP="checkout"
log "$STEP"
as_app "git checkout --quiet --detach $SHA"

STEP="bundle install"
log "$STEP"
as_app "bundle install --quiet"

STEP="yarn install"
log "$STEP"
as_app "yarn install --immutable"

STEP="db:migrate(post-deploy以外)"
log "$STEP"
MIGRATED=1
as_app "SKIP_POST_DEPLOY_MIGRATIONS=true bundle exec rails db:migrate"

STEP="assets:precompile"
log "$STEP"
as_app "bundle exec rails assets:precompile"

STEP="ソースのリンク(.env.production)"
log "$STEP"
ENV_FILE="$APP_DIR/.env.production"
set_env() {
  if grep -q "^$1=" "$ENV_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}
set_env GITHUB_REPOSITORY "$FORK_REPO"
set_env SOURCE_TAG "$SHA"

STEP="再起動"
log "$STEP"
systemctl restart mastodon-web mastodon-sidekiq $STREAMING_UNITS

STEP="db:migrate(post-deploy)"
log "$STEP"
as_app "bundle exec rails db:migrate"

# ---------------------------------------------------------------
STEP="動作確認"
log "$STEP"
for unit in mastodon-web mastodon-sidekiq $STREAMING_UNITS; do
  systemctl is-active --quiet "$unit" || { echo "$unit が動いていません"; systemctl status "$unit" --no-pager | tail -20; false; }
  echo "$unit: active"
done

DOMAIN="$(grep '^LOCAL_DOMAIN=' "$ENV_FILE" | cut -d= -f2)"
EXPECTED="$(as_app "git show $SHA:lib/mastodon/version.rb" | awk '/def (major|minor|patch)$/{getline; gsub(/ /,""); v=v (v?".":"") $0} END{print v}')"
VERSION=""
for _ in $(seq 1 30); do
  VERSION="$(curl -fsS -H "Host: $DOMAIN" -H 'X-Forwarded-Proto: https' \
    "http://127.0.0.1:3000/api/v2/instance?nocache=$RANDOM" 2>/dev/null \
    | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)" || true
  [[ -n "$VERSION" ]] && break
  sleep 5
done
echo "期待: $EXPECTED / 実際: ${VERSION:-(応答なし)}"
[[ "$VERSION" == "$EXPECTED"* ]] || { echo "版が一致しません"; false; }

trap - ERR
log "完了: $PREV_SHA → $SHA ($LABEL)"
echo "バックアップ: $BACKUP_FILE"
