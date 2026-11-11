#!/usr/bin/env bash
# Sets up Expressive Helpdesk. Run it from this folder in Terminal on the Mac:
#
#   ./setup.sh
#
# It asks for the bot token and a Claude API key (typed or pasted in, not shown, kept only in the
# Worker's secrets), deploys the Worker and points Telegram at it. Safe to run again: it makes a
# new webhook secret and updates the hook. The bot starts answering as soon as this finishes.
set -euo pipefail
cd "$(dirname "$0")"

CHAT_ID="-1004427242312"           # Expressive Group Chat (CHAT_ID in cloudflare.config.ts)
BUCKET="expressiveos-helpdesk-bot" # STATE
URL="${BOT_URL:-https://expressiveos-helpdesk-bot.daryldenson-apps.workers.dev}"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() {
	printf '\n\033[31m%s\033[0m\n' "$*" >&2
	exit 1
}
# Reads JSON on stdin and prints one value: jget 'd.result.username'
jget() { node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{let v;try{v=new Function("d","return "+process.argv[1])(JSON.parse(s))}catch{};console.log(v??"")})' "$1"; }
# -4: the Mac's IPv6 route to Telegram can hang
tg() { curl -4 -sS --max-time 30 "https://api.telegram.org/bot$TG_TOKEN/$1" "${@:2}"; }

command -v node >/dev/null || fail "Node.js is needed (brew install node)."

read -rsp "Telegram bot token for @expressive_helpdesk_bot (from @BotFather): " TG_TOKEN
echo
[[ $TG_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail "That doesn't look like a bot token (numbers:letters)."
read -rsp "Claude API key (Claude Console > API keys > Create key): " CLAUDE_KEY
echo
[[ $CLAUDE_KEY =~ ^sk-ant-[A-Za-z0-9_-]+$ ]] || fail "That doesn't look like a Claude API key (it starts with sk-ant-)."

bold "Checking the bot"
me=$(tg getMe)
[[ $(jget 'd.ok' <<<"$me") == true ]] || fail "Telegram didn't accept the bot token: $(jget 'd.description' <<<"$me")"
BOT_ID=$(jget 'd.result.id' <<<"$me")
BOT_NAME=$(jget 'd.result.username' <<<"$me")
member=$(tg getChatMember -d chat_id="$CHAT_ID" -d user_id="$BOT_ID")
status=$(jget 'd.result && d.result.status' <<<"$member")
if [[ $status == administrator ]]; then
	echo "@$BOT_NAME is an admin of Expressive Group Chat: it will answer in the support topics."
else
	echo "@$BOT_NAME isn't an admin of Expressive Group Chat (Telegram says: ${status:-$(jget 'd.description' <<<"$member")})."
	echo "It will answer private chats only. To add the support topics later: add it to the group and make it"
	echo "an admin (no admin rights ticked). No need to run this again."
fi
if [[ $(jget 'd.result.can_connect_to_business' <<<"$me") == true ]]; then
	echo "Business Mode is on: it can answer in your own chats once you add it under Telegram Business > Chatbots."
else
	echo "Business Mode is off, so it can't answer in your own chats. To allow that: @BotFather > /mybots >"
	echo "@$BOT_NAME > Bot Settings > Business Mode > Turn on."
fi

bold "Checking the Claude API key"
code=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models \
	-H "x-api-key: $CLAUDE_KEY" -H "anthropic-version: 2023-06-01")
[[ $code == 200 ]] || fail "Claude didn't accept the API key (HTTP $code)."
echo "The key works."

TG_SECRET=$(openssl rand -hex 32)

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
printf '{"TELEGRAM_BOT_TOKEN":"%s","TELEGRAM_WEBHOOK_SECRET":"%s","ANTHROPIC_API_KEY":"%s"}\n' \
	"$TG_TOKEN" "$TG_SECRET" "$CLAUDE_KEY" >"$secrets"
npx cf deploy --secrets-file "$secrets" --message "setup.sh"
rm -f "$secrets"
for _ in 1 2 3 4 5 6; do
	curl -fsS --max-time 10 "$URL/" >/dev/null 2>&1 && break
	sleep 5
done
curl -fsS --max-time 10 "$URL/" >/dev/null || fail "The Worker doesn't answer at $URL yet. If cf deploy printed another address, run again with BOT_URL=<that address> ./setup.sh"

bold "Pointing Telegram at the Worker"
# drop_pending_updates: messages sent before now (tests through Zapier) get no late answers
hook=$(tg setWebhook -d url="$URL/telegram" -d secret_token="$TG_SECRET" -d max_connections=1 -d drop_pending_updates=true \
	--data-urlencode 'allowed_updates=["message","business_connection","business_message"]')
[[ $(jget 'd.ok' <<<"$hook") == true ]] || fail "setWebhook failed: $(jget 'd.description' <<<"$hook")"
echo "Telegram sends updates to $URL/telegram."

bold "All set"
echo "Message @$BOT_NAME \"How do I install ExpressiveOS?\": it answers within a few seconds."
echo "Switch it off or on from your private chat with it: /helpdesk off, /helpdesk on, /helpdesk status."
echo "Don't publish the Zapier Zap for this bot: Zapier would take the bot's updates away from the Worker."
