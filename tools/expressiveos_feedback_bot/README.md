# ExpressiveOS feedback bot

A Telegram bot in Expressive Group Chat that turns posts in the **Bugs** and **Ideas** topics into issues in the private
repo [`denson9874/expressiveos-feedback`](https://github.com/denson9874/expressiveos-feedback), and tells each post
when its issue is planned or fixed. Claude's cloud sessions can't reach Telegram or Cloudflare, but they can read and
update GitHub issues, so the issues are where feedback gets triaged and acted on.

It's one Cloudflare Worker, `expressiveos-feedback-bot`, on the same account as the web installer, at
`https://expressiveos-feedback-bot.daryldenson-apps.workers.dev`. Nothing runs on the build server or the Mac.

## What it does

**In Telegram**

- A new post in Bugs or Ideas becomes an issue labelled `bug` or `idea`, plus `phone:<codename>` for each phone it
  names and `launcher` when it's about the launcher. The issue quotes the post and has who posted it, a link back,
  the time (ET), and its file (a log, screenshot or video up to 10 MB, committed under `attachments/`).
- The bot reacts 👀 to the post. A bug that lacks the pinned template's phone, build date or log gets one reply
  asking for what's missing.
- Replies to a logged post, replies to the bot's messages, the rest of an album and edits are added to the same issue
  as comments, files included.
- 👍 reactions on a logged post count as votes (the Ideas topic asks for them): the issue's `👍 votes` line keeps the
  count.
- Admins can reply `/track` to any message anywhere in the chat to log it (`/track idea` logs it as an idea).
  (`/bug` is Rose's filter, so the bot's command is `/track`.)
- "ok", "thanks", "+1", emoji-only posts and commands aren't logged on their own. Other topics are only read for
  replies to logged messages and for `/track`.

**From GitHub** (each answer goes out once, as a reply to the issue's first post)

| On the issue | The bot says |
|---|---|
| Closed as completed | "✅ Fixed in *milestone*, out *due date*. Thanks for reporting it!" (ideas: "✅ Added in …") |
| Label `planned` | "📌 We're on it: planned for *milestone*, out *due date*." (ideas: "📌 Planned for …") |
| Label `needs-logs` | how to take a log, and the link to which logs each problem needs |
| Comment `/reply <text>` by `denson9874` | *text*, as written, up to a `---` line (🚀 on the comment once it's sent, 😕 if it failed) |
| Closed as not planned or duplicate | nothing |
| Label `no-reply` | nothing automatic (`/reply` still works) |

Without a milestone, the fixed and planned notices say "the next update" and "an upcoming update". Every word the bot
can say is in [`src/messages.ts`](src/messages.ts).

## Acting on feedback

- New issues come in with `bug` or `idea` and the phone labels. "Missing from the post" lists what the template asked
  for and didn't get.
- Duplicates: close as duplicate with "Duplicate of #N" (the bot stays quiet).
- Need a log: add `needs-logs`.
- Going into a release: set the release's milestone (for example "ExpressiveOS 1.1", due Dec 3), then add `planned`.
- Fixed: close as completed once the fix is merged for that release. A PR in another repo can close it with
  `Fixes denson9874/expressiveos-feedback#N`.
- To answer in your own words: comment `/reply <text>`.

## Set up (once, about 10 minutes)

1. **Bot:** in Telegram, message [@BotFather](https://t.me/BotFather), send `/newbot`, give it a name (for example
   "Expressive Feedback") and a username ending in `bot`, and copy the token it sends.
2. **Group:** add the bot to Expressive Group Chat and make it an admin. It needs none of the admin rights: being an
   admin is what lets a bot see every message and every reaction.
3. **Repo:** create the **private** repo `denson9874/expressiveos-feedback` on GitHub (a README is fine).
4. **Token:** GitHub → Settings → Developer settings →
   [Fine-grained tokens](https://github.com/settings/personal-access-tokens/new): repository access *Only select
   repositories* → `expressiveos-feedback`; repository permissions **Contents**, **Issues** and **Webhooks**, each
   *Read and write*. Copy the token.
5. **Deploy:** in Terminal, from this folder:

   ```sh
   ./setup.sh
   ```

   It asks for the two tokens, checks the bot is an admin and the repo is private, deploys the Worker with its secrets
   (`cf` may ask you to sign in to Cloudflare), points Telegram and the repo's webhook at it, and makes the labels.
   Then post a test in Bugs: the bot reacts 👀 within a few seconds and the issue shows up in the repo.

Code changes later deploy with `npm ci && npm run deploy`, which keeps the secrets. Running `./setup.sh` again makes new
webhook secrets and updates both webhooks (for a new token, for example).

## Limits

- The bot sees only what's posted after it joins.
- Telegram lets bots download files of up to 20 MB, and the bot saves files of up to 10 MB (`MAX_ATTACHMENT_MB`);
  bigger ones get a note in the issue to ask for a link.
- If Telegram or GitHub fails, Telegram sends the post again (up to 5 tries; from the third the file is skipped so
  the report itself gets in). A GitHub event that fails shows as a failed delivery under the repo's webhook settings,
  where it can be redelivered.
- It doesn't answer questions on its own. Rose's filters still do the FAQ.

## Development

```sh
npm ci
npm test            # node --test (Node 22.18 or newer runs the TypeScript directly)
npm run typecheck
```

`cloudflare.config.ts` holds the chat id, the topic ids (Bugs 753, Ideas 751), the repo and who may `/reply`. The R2
bucket `expressiveos-feedback-bot` (binding `STATE`) holds only small records: which Telegram message belongs to which
issue, the vote counts, and which answers went out.
