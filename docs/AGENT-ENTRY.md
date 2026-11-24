# An entry for other programs

RenderDock finds renders and coding agents' sessions by itself. Anything else has no way to appear on the dock, or on a device on the desk, unless it says so. This is how it says so: three commands, for any script or agent that can run a command.

```sh
renderdock notify "All 42 tests passed" --title "Build" --level done
renderdock progress import --title "Import the catalogue" --percent 40 --eta 300
renderdock ask "The export works. Remove the old endpoint as well?" --choice "Remove it" --choice "Keep it"
```

| Command | What it does |
|---|---|
| `notify` | Puts a short notice on the dock, and on a desk device for a few seconds |
| `progress` | Shows how far a task of the caller's own has got, the way a render's progress is shown |
| `ask` | Puts a question with two to four answers in front of the user, waits, and prints the answer they picked |

**Off by default.** Switch on "Take Notices, Progress and Questions from Other Programs" in RenderDock's menu (or start it with `--inbox`). Until then nothing listens, and each command says so and exits with status 3.

The command is `renderdock`, at `RenderDock.app/Contents/Helpers/renderdock`.

## What this is not

It is not the way an agent gets permission to do something. That is [answering agents](ANSWERING-AGENTS.md), which has its own switch, its own rules about what may be allowed from a display, and a record of every answer. A question asked here is the caller's own question. Its answer is one of the answers the caller wrote, it goes back to the caller and to nobody else, and RenderDock allows or refuses nothing because of it. On the dock and on a device a question is drawn in a colour of its own (lilac), where a request for permission is amber, and the two travel to a device under different names and come back as different messages. One can never be taken for the other.

What the caller does with the answer is the caller's business. An agent that asks "may I delete the build folder?" through `ask` and then deletes it has not been given permission by its own permission system; it has asked a person and been told yes. Whether that is good enough is between you and that agent.

## The three commands

### notify

```
renderdock notify TEXT [--title TITLE] [--level info|done|error] [--from NAME]
```

The text may be several words without quotes; everything after `--` is text even if it starts with dashes. `--level` picks the mark and, on a device, the sound: `info` (the default), `done` or `error`.

A notice stays in the panel for ten minutes, or until you dismiss it. A device shows a new one full-screen for eight seconds (a touch or a key takes it away sooner) and does not show it again. Only the last eight are kept, and more than thirty in a minute are refused.

### progress

```
renderdock progress NAME [--title TITLE] [--percent 0-100] [--eta SECONDS] [--done | --failed] [--from NAME]
```

`NAME` is the caller's own name for the task: a later report with the same name (and the same `--from`) updates the same line. `--title` is what is shown; it is kept from one report to the next. `--percent` may be left out when the caller cannot say; the task then shows as going, without a number. `--eta` is the caller's own estimate and is dropped when a later report does not repeat it.

End a task with `--done` or `--failed`. A task nobody has reported on for ten minutes is taken off the list; a finished one stays for five. There is room for eight.

```sh
renderdock progress import --title "Import the catalogue" --percent 0
for i in 1 2 3 4; do
  do_a_quarter "$i"
  renderdock progress import --percent $((i * 25))
done
renderdock progress import --done
```

On a device a task with a percentage has the ring a render has. A render or a session at work keeps the main screen over a task at work; a task that has just failed takes it for a minute. Tasks are always in the list.

### ask

```
renderdock ask TEXT --choice A --choice B [--choice C] [--choice D] [--timeout SECONDS] [--from NAME] [--json]
```

Prints the answer that was picked, and nothing else, so a script can use it as it is:

```sh
case "$(renderdock ask "Tests pass. Commit now?" --choice Commit --choice "Not yet" --from "my script")" in
  Commit) git commit -am "Checkpoint" ;;
  *)      echo "left uncommitted" ;;
esac
```

With `--json` it prints `{"choice":"Commit","index":0}` instead.

- The question may be up to 120 characters and each answer up to 14. **A question that is too long is refused, not shortened**: the user would be answering something other than what was asked.
- It waits 120 seconds unless `--timeout` says otherwise (5 to 600). With no answer by then, or if you press "No answer" in the panel, the command exits with status 2 and prints nothing. Write the script so that no answer is the safe case.
- Four questions may wait at once, and no more than twelve are taken in a minute. If the caller goes away, so does its question.

A question can be answered in the panel or on a desk device, whichever you reach first.

### Exit status

| Status | Meaning |
|---|---|
| 0 | It worked. For `ask`: an answer was picked, and is on standard output |
| 2 | `ask` only: nobody answered (time ran out, it was dismissed, or RenderDock quit) |
| 3 | RenderDock is not running, or the entry is switched off |
| 64 | The command line was wrong; the reason is on standard error |
| 65 | RenderDock refused it (too many notices, tasks or questions at once); the reason is on standard error |

### Who is speaking

`--from`, or the `RENDERDOCK_FROM` environment variable, is shown next to whatever was sent. **Nothing checks it.** Any program running as you can use any name, so it is a label, not a proof of who is asking.

## Telling an agent about it

An agent uses this the way it uses any command. A few lines in the instructions it reads (a `CLAUDE.md`, an `AGENTS.md`) are enough, for example:

```markdown
When a step will take more than a minute, report on it with
`renderdock progress <name> --title "<what>" --percent <n>` and finish with `--done` or `--failed`.
When you are done with a long task, run `renderdock notify "<one line>" --level done`.
When you need me to choose between a few options and I may be away from the keyboard, run
`renderdock ask "<question>" --choice "<A>" --choice "<B>"` and act on what it prints.
If it exits with status 2 or 3, ask me in the conversation instead.
```

Nothing is installed into any agent's settings by RenderDock, and no agent uses these commands unless you tell it to.

## On a desk device

Any other device is told how many things are running and waiting, and one line that says a question is waiting. It is not sent a word of what was asked, said or reported.

A device that speaks RenderDock's extra fields ([DEVICES.md](DEVICES.md)) and says it understands these gets, on an encrypted link only:

- a new notice, for the first minute after it arrives;
- tasks, as rows of its list and, when nothing else has a better claim, as the main screen;
- the oldest question it is able to draw.

A question is answered on the device by **holding** one of its answers for a second. The device decides whether it can show a question whole, answers and all; one it cannot is shown as "answer on the computer", with nothing to press. As with requests, RenderDock takes a pick only for a question it offered on that connection, and only once.

## What is kept, and where it goes

- Everything is held in memory. Nothing a caller sends is written to disk, and it is gone when RenderDock quits or the switch goes off.
- A notice or a question raises a notification on this Mac if "Notify on This Mac" is on. It is **never** passed on to the push channels in `notify.json`: what other programs say stays on this Mac and on a paired device.
- None of it is in the [local API](API.md).
- The entry is a Unix socket in `~/Library/Application Support/RenderDock/inbox`, a directory only you can enter, with a token that changes every time the entry starts. Other users of this Mac cannot reach it. Any program running as **you** can: this does not tell your own programs apart.

## What has and has not been checked

- **Checked**, by checks that run the real command against the real listener: every command with its exit statuses, the limits, a question being answered, dismissed, timing out, and the app going away while one waits; what a device is sent and what is held back; a pick coming back.
- **Checked on one device** with made-up snapshots fed over USB: every screen, and holding an answer with a finger put down from the console.
- **Checked once, the whole way round over Bluetooth**, with the installed app and the desk display in [`firmware/desk-display`](../firmware/desk-display/README.md): a notice and a task sent with the commands showed on the device; a question asked with `ask` came up there, was answered by a real finger held on one of its answers, and the command printed that answer. A first hold of 0.9 seconds picked nothing, as it should.
- **Not checked yet**: a question running out of time or being put aside on a real device; several questions at once on a device.

## Not there yet

- An MCP server, for agents that would rather call a tool than run a command.
- Anything over the network. The entry is for programs on this Mac.
- Free-text answers. A question has two to four fixed answers.
