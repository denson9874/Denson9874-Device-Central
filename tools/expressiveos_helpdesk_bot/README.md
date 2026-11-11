# Expressive Helpdesk bot

The Telegram bot **Expressive Helpdesk** (`@expressive_helpdesk_bot`) answers questions about ExpressiveOS and
Expressive Launcher with Claude. It is an automated helper and says so; it never speaks as Daryl.

It's one Cloudflare Worker, `expressiveos-helpdesk-bot`, on the same account as the web installer and the feedback
bot, at `https://expressiveos-helpdesk-bot.daryldenson-apps.workers.dev`. Nothing runs on the build server or the Mac.
It is a different bot from the feedback bot and stays out of its topics (Bugs and Ideas).

## Where it answers

| Place | What it does |
|---|---|
| A private chat with the bot | Answers every text message. `/start` gets a short introduction. |
| Expressive Group Chat: ROM Support, Launcher Support, Install & Updates | Reads every post and answers the ones that are questions it can answer, as a reply in the same topic. It stays silent on chatter, thanks and anything it isn't sure about. |
| Daryl's own chats (Telegram Business) | Answers only clear ExpressiveOS or launcher questions, under the line "🤖 Automated reply from Expressive Helpdesk (Daryl will see this chat too):". Silent on everything else. |

It never answers:

- admins of the group, other bots, commands, and posts made as the group or a channel;
- a reply one member writes to another (a reply to the bot's own message does continue the conversation);
- in one of Daryl's own chats for 12 hours after he writes there himself (`OWNER_QUIET_HOURS`);
- pictures, files or voice messages without text (in a private chat it says it can only read text);
- more than 10 times an hour for one person, or 300 times a day in total (`MAX_REPLIES_PER_USER_HOUR`,
  `MAX_REPLIES_PER_DAY`): the guards on what the Claude API key can spend.

## What it says

Everything the bot knows and its rules are in [`src/instructions.ts`](src/instructions.ts): the facts of the current
release, where to send people, and what it never does (no keybox, attestation or Play Integrity help; no claims about
Wallet, banking apps or Gemini Nano; no root guides; no promises of fixes or dates). It answers only from those
facts and says so when it doesn't know. **Update the release number and facts there with each release**, then
`npm run deploy`.

It remembers the last few messages of a conversation for 6 hours (in the R2 bucket `expressiveos-helpdesk-bot`,
with the counters and the on/off switch). Message text goes to the Claude API to be answered; names and usernames
do not.

## Switching it off

In a private chat with the bot, an admin of Expressive Group Chat can send:

- `/helpdesk off`: it answers nobody, anywhere, until
- `/helpdesk on`
- `/helpdesk status`

For Daryl's own chats there is also Telegram's own switch: Settings > Telegram Business > Chatbots.

## Setup (once, on the Mac)

1. In `@BotFather`: `/mybots` > Expressive Helpdesk > Bot Settings > **Business Mode** > Turn on (only needed for
   Daryl's own chats).
2. Add the bot to Expressive Group Chat and make it an admin with no rights ticked (admins receive every message;
   only needed for the support topics).
3. Create a key in Claude Console (API keys > Create key).
4. Run `./setup.sh` and paste the bot token and the key when asked. It checks both, deploys, and points Telegram
   at the Worker. The bot answers from that moment.
5. For Daryl's own chats: Telegram > Settings > Telegram Business > Chatbots > add `@expressive_helpdesk_bot`,
   allow it to reply, and choose which chats it may see. Excluding **Contacts** keeps it out of chats with family
   and friends.

Don't publish a Zapier Zap that uses this bot: a bot's updates go to one place, and Zapier would take them.

## Development

```
npm ci
npm test            # offline: Telegram, Claude and R2 are faked (test/world.ts)
npm run typecheck
npm run deploy      # after setup.sh has set the secrets once
```

The model is `MODEL` in `cloudflare.config.ts`.
