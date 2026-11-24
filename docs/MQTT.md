# MQTT, and Home Assistant

> New in 0.3. Off unless you set it up.

RenderDock can publish what it sees to an MQTT broker. From there a home-automation system can show it or act on it: a lamp that turns green when the queue is done, a dashboard tile with the percentage, a notification when something has stalled.

**Nothing is published unless a settings file names a broker and says `"enabled": true`.** There is no broker built in and none is looked for.

## Setting it up

Menu-bar icon → **MQTT** → **Edit MQTT Settings…** creates and opens `~/Library/Application Support/RenderDock/mqtt.json` (readable by you alone, since it may hold a password):

```json
{
  "enabled": false,
  "host": "192.168.1.10",
  "port": 1883,
  "tls": false,
  "username": "",
  "password": "",
  "topic": "renderdock",
  "names": true,
  "homeAssistant": true
}
```

Put in your broker's address, set `enabled` to `true`, and save. The file is read again every few seconds, so there is nothing to restart. The menu says whether it is connected, and why not if it is not.

| Setting | Meaning |
|---|---|
| `host`, `port` | The broker. The port is 1883 unless given, or 8883 with `tls` |
| `tls` | `true` to connect with TLS. The broker's certificate must be one this Mac trusts |
| `username`, `password` | If the broker asks for them |
| `topic` | The first part of every topic. Give each Mac its own (`studio/mac-2`) when there are several |
| `names` | `false` to leave the shot's and the job's names out. The numbers still go |
| `homeAssistant` | `false` to not announce the sensors to Home Assistant |
| `discoveryPrefix` | Home Assistant's discovery topic, if you changed it from `homeassistant` |

## What is published

Two topics, both retained, so that whoever subscribes later gets the current value at once.

`<topic>/availability` is `online` while RenderDock is connected and `offline` when it has gone. If the Mac sleeps or the app is killed, the broker says `offline` for it (an MQTT "last will").

`<topic>/state` is one JSON document, published when something in it changes:

```json
{"state":"working","rendering":2,"paused":1,"stalled":0,"queued":1,
 "progress":62,"exact":true,"eta":1500,"shot":"s040_explode","job":"Product film",
 "agents_waiting":0,"agents_working":2,"agents_error":0}
```

| Field | Meaning |
|---|---|
| `state` | `error`, `waiting`, `working`, `done` or `idle`: renders and coding agents together, as one word (see [SMALL-DISPLAYS.md](SMALL-DISPLAYS.md)) |
| `rendering`, `paused`, `stalled`, `queued` | How many shots are in each state |
| `progress` | The shot in front, 0 to 100. It is 0 while nothing renders, so that a gauge always has a number |
| `exact` | `false` when the total behind that percentage is an estimate |
| `eta` | Seconds until that shot is done; 0 when not known |
| `shot`, `job` | Their names; empty with `"names": false` |
| `agents_waiting`, `agents_working`, `agents_error` | Coding agents' sessions, counted. Never their projects or titles |

That is all that leaves the Mac this way. No paths, no host name, no command lines, nothing from other programs' notices or questions.

## Home Assistant

With its MQTT integration set up, Home Assistant finds RenderDock by itself (its "MQTT discovery") and creates one device with these entities:

| Entity | Kind |
|---|---|
| State, Progress (%), Time left (s), Rendering, Queued, Agents waiting, Agents working | sensors |
| Shot, Job | sensors (not with `"names": false`) |
| Rendering now | binary sensor: on while anything renders |
| Needs attention | binary sensor: on while a shot is stalled, or an agent is waiting or has failed |

An automation that turns a lamp green when the queue finishes then needs one trigger: `Rendering now` going from on to off.

Anything else that speaks MQTT can use the two topics directly. A WLED strip, for one, can be driven from Home Assistant or Node-RED with `progress`; for a strip with nothing in between, see [examples/wled-progress](../examples/wled-progress/README.md).

## How it behaves

- MQTT 3.1.1, quality of service 0: each message is sent once and not acknowledged. The state is small and sent again whenever it changes, so a lost message is corrected by the next.
- If the broker cannot be reached, or refuses the password, the menu says so and RenderDock tries again after 5 seconds, then 10, 20, up to two minutes apart.
- Turning it off (`"enabled": false`, or removing the file) says `offline` and disconnects.

## What has and has not been checked

- **Checked** against a stand-in broker in the project's own checks: every packet byte for byte, the order (online, the sensors, the state), that an unchanged state is not sent twice, the goodbye, a refused password, a broker that is not there.
- **Not checked: a real broker, and Home Assistant.** The author has neither. The packets follow the MQTT 3.1.1 specification and the discovery messages follow Home Assistant's documentation, but nobody has yet watched the entities appear. If you try it, a report either way is welcome.
