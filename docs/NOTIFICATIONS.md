# Notifications

> New in 0.2. Everything here is off until you turn it on.

RenderDock can tell you when a job ends, when one stalls, and when the queue is empty: on the Mac, and on your phone through a service you already use.

Menu-bar icon → **Notifications**.

## On this Mac

**Notify on This Mac** turns on ordinary macOS notifications. The first time, macOS asks for permission. If it was refused earlier, allow it under System Settings → Notifications → RenderDock.

## On your phone

**Edit Push Settings…** opens `~/Library/Application Support/RenderDock/notify.json`. The first time, it is created with examples that are all switched off. The file is readable only by you, because it will hold keys.

```json
{
  "channels": [
    { "type": "bark", "key": "YOUR_DEVICE_KEY" },
    { "type": "feishu", "url": "https://open.feishu.cn/open-apis/bot/v2/hook/YOUR_HOOK" }
  ]
}
```

| `type` | Needs | Notes |
|---|---|---|
| `bark` | `key` | iOS. `server` for a self-hosted one |
| `ntfy` | `topic` | iOS and Android. `server` for a self-hosted one |
| `feishu` | `url` | A custom bot's webhook address |
| `wecom` | `url` | A group robot's webhook address |
| `dingtalk` | `url` | A custom robot's webhook address. If the robot filters by keyword, the keyword must appear in the message |
| `telegram` | `token`, `chat_id` | A bot token and the chat to write to |
| `webhook` | `url` | Anything else: `method`, `headers`, and a `body` template |

Every channel also takes:

- `"events": ["job.ended", "job.stalled", "all.ended", "shot.done"]` — which events it announces. The default is the first three; `shot.done` is left out because a long queue would be noisy.
- `"enabled": false` — keep the entry but send nothing.

The file is read each time a notification goes out, so there is nothing to restart. **Send a Test Notification** sends one message to every enabled channel; if a channel answers with an error, the menu shows it.

### A generic webhook

```json
{
  "type": "webhook",
  "url": "https://example.com/hook",
  "headers": { "Authorization": "Bearer …" },
  "body": "{\"text\": \"{title}: {body}\", \"event\": \"{event}\", \"job\": \"{job}\"}"
}
```

Placeholders: `{title}`, `{body}`, `{event}`, `{job}`, `{project}`. In a JSON body the values are escaped for you. Without a `body`, RenderDock posts `{"title", "body", "event", "job", "project"}`.

## What the messages say

| Event | Message |
|---|---|
| `job.ended`, started with `renderdock run`, exit status 0 | **Render finished** — the job's title |
| `job.ended`, started with `renderdock run`, any other exit status | **Render failed** — the title and the exit status |
| `job.ended`, not wrapped | **Render job ended** — RenderDock cannot tell a finished render from a crashed one, so it does not claim either |
| `job.stalled` | **Render may be stalled** |
| the last job ends | the same message, with "nothing else is running" added |
| `all.ended` on its own | **All render jobs have ended** |

To get "finished" and "failed", start the job through the wrapper: see [EXACT-PROGRESS.md](EXACT-PROGRESS.md).

## What leaves your Mac

Nothing, unless you add a channel. With a channel configured, each notification is one HTTPS request to that service containing the message text, which includes the job's title. These are the only outbound connections RenderDock ever makes.

## What has and has not been checked

The request each channel sends was checked against a local stand-in server, not against the real services: RenderDock has no account with any of them. If a channel does not work with your key, **Send a Test Notification** and the error line in the menu are the place to start, and a bug report is welcome.
