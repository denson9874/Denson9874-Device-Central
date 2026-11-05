#!/usr/bin/env bash
# Sets up the ExpressiveOS feedback bot. Run it from this folder in Terminal on the Mac:
#
#   ./setup.sh
#
# It asks for the bot token and the GitHub token (typed in, not shown, kept only in the Worker's
# secrets), deploys the Worker, then points Telegram and the feedback repo's webhook at it and
# makes the repo's labels. Safe to run again: it makes new webhook secrets and updates both hooks.
set -euo pipefail
cd "$(dirname "$0")"

REPO="denson9874/expressiveos-feedback" # GITHUB_REPO in cloudflare.config.ts
CHAT_ID="-1004427242312"                # Expressive Group Chat (CHAT_ID)
BUCKET="expressiveos-feedback-bot"      # STATE
URL="${BOT_URL:-https://expressiveos-feedback-bot.daryldenson-apps.workers.dev}"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() {
	printf '\n\033[31m%s\033[0m\n' "$*" >&2
	exit 1
}
# Reads JSON on stdin and prints one value: jget 'd.result.username'
jget() { node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{let v;try{v=new Function("d","return "+process.argv[1])(JSON.parse(s))}catch{};console.log(v??"")})' "$1"; }
# -4: the Mac's IPv6 route to Telegram can hang
tg() { curl -4 -sS --max-time 30 "https://api.telegram.org/bot$TG_TOKEN/$1" "${@:2}"; }
gh_api() { curl -sS --max-time 30 -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

command -v node >/dev/null || fail "Node.js is needed (brew install node)."

read -rsp "Telegram bot token (from @BotFather): " TG_TOKEN
echo
[[ $TG_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail "That doesn't look like a bot token (numbers:letters)."
read -rsp "GitHub token for $REPO: " GH_TOKEN
echo
[[ $GH_TOKEN =~ ^[A-Za-z0-9_]+$ ]] || fail "That doesn't look like a GitHub token."

bold "Checking the bot"
me=$(tg getMe)
[[ $(jget 'd.ok' <<<"$me") == true ]] || fail "Telegram didn't accept the bot token: $(jget 'd.description' <<<"$me")"
BOT_ID=$(jget 'd.result.id' <<<"$me")
BOT_NAME=$(jget 'd.result.username' <<<"$me")
member=$(tg getChatMember -d chat_id="$CHAT_ID" -d user_id="$BOT_ID")
status=$(jget 'd.result && d.result.status' <<<"$member")
[[ $status == administrator ]] || fail "@$BOT_NAME isn't an admin of Expressive Group Chat yet (Telegram says: ${status:-$(jget 'd.description' <<<"$member")}).
Add it to the group, make it an admin (it needs no admin rights ticked), then run this again."
echo "@$BOT_NAME is an admin of Expressive Group Chat."

bold "Checking the GitHub repo"
repo=$(gh_api "https://api.github.com/repos/$REPO")
[[ $(jget 'd.full_name' <<<"$repo") ]] || fail "GitHub didn't find $REPO with that token: $(jget 'd.message' <<<"$repo")"
[[ $(jget 'd.private' <<<"$repo") == true ]] || fail "$REPO is public. Make it private first: posts and logs can hold personal info."
echo "$REPO is there and private."

TG_SECRET=$(openssl rand -hex 32)
GH_SECRET=$(openssl rand -hex 32)

bold "Deploying the Worker"
npm ci --no-audit --no-fund
npx cf auth whoami >/dev/null 2>&1 || npx cf auth login
# </dev/null: a prompt fails instead of waiting unseen. On a second run the bucket is already there.
if npx cf r2 buckets create --name "$BUCKET" </dev/null >/dev/null 2>&1; then
	echo "Made the R2 bucket $BUCKET."
else
	echo "R2 bucket $BUCKET: already there, or cf deploy makes it."
fi
umask 077
secrets=$(mktemp)
trap 'rm -f "$secrets"' EXIT
printf '{"TELEGRAM_BOT_TOKEN":"%s","TELEGRAM_WEBHOOK_SECRET":"%s","GITHUB_TOKEN":"%s","GITHUB_WEBHOOK_SECRET":"%s"}\n' \
	"$TG_TOKEN" "$TG_SECRET" "$GH_TOKEN" "$GH_SECRET" >"$secrets"
npx cf deploy --secrets-file "$secrets" --message "setup.sh"
rm -f "$secrets"
for _ in 1 2 3 4 5 6; do
	curl -fsS --max-time 10 "$URL/" >/dev/null 2>&1 && break
	sleep 5
done
curl -fsS --max-time 10 "$URL/" >/dev/null || fail "The Worker doesn't answer at $URL yet. If cf deploy printed another address, run again with BOT_URL=<that address> ./setup.sh"

bold "Pointing Telegram at the Worker"
hook=$(tg setWebhook -d url="$URL/telegram" -d secret_token="$TG_SECRET" -d max_connections=1 \
	--data-urlencode 'allowed_updates=["message","edited_message","message_reaction"]')
[[ $(jget 'd.ok' <<<"$hook") == true ]] || fail "setWebhook failed: $(jget 'd.description' <<<"$hook")"
echo "Telegram sends updates to $URL/telegram."

bold "Pointing the repo's webhook at the Worker"
config=$(node -e 'console.log(JSON.stringify({name:"web",active:true,events:["issues","issue_comment"],config:{url:process.argv[1],content_type:"json",secret:process.argv[2],insecure_ssl:"0"}}))' "$URL/github" "$GH_SECRET")
hooks=$(gh_api "https://api.github.com/repos/$REPO/hooks")
hook_id=$(jget "((Array.isArray(d) && d.find(h => h.config && h.config.url === '$URL/github')) || {}).id" <<<"$hooks")
if [[ $hook_id ]]; then
	result=$(gh_api -X PATCH "https://api.github.com/repos/$REPO/hooks/$hook_id" -d "$config")
else
	result=$(gh_api -X POST "https://api.github.com/repos/$REPO/hooks" -d "$config")
fi
[[ $(jget 'd.id' <<<"$result") ]] || fail "GitHub didn't take the webhook: $(jget 'd.message' <<<"$result") (the token needs Webhooks: Read and write)"
echo "GitHub sends issue events to $URL/github."

bold "Making the labels"
while IFS='|' read -r name color description; do
	body=$(node -e 'console.log(JSON.stringify({name:process.argv[1],color:process.argv[2],description:process.argv[3]}))' "$name" "$color" "$description")
	gh_api -o /dev/null -X POST "https://api.github.com/repos/$REPO/labels" -d "$body" || true # 422 = already there
done <<'EOF'
bug|d73a4a|From the Bugs topic
idea|a2eeef|From the Ideas topic
planned|0e8a16|The bot tells the post it's planned (with the milestone)
needs-logs|fbca04|The bot asks the post for a log
no-reply|cccccc|The bot says nothing about this issue
launcher|5319e7|Expressive Launcher
phone:cheetah|1d76db|Pixel 7 Pro
phone:husky|1d76db|Pixel 8 Pro
phone:cubs|1d76db|Pixel 11
phone:grizzly|1d76db|Pixel 11 Pro
phone:kodiak|1d76db|Pixel 11 Pro XL
phone:yogi|1d76db|Pixel 11 Pro Fold
EOF
echo "Done."

bold "All set"
echo "Post a test in the Bugs topic (for example \"Test, please ignore\"). Within a few seconds @$BOT_NAME reacts 👀,"
echo "asks for the phone, build and log, and the post shows up at https://github.com/$REPO/issues."
echo "Close that test issue as \"not planned\" so the bot stays quiet about it."
