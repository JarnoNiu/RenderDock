# An LED strip as a progress bar

`wled_progress.py` fills a [WLED](https://kno.wled.ge) strip to match the render in front: half way through the shot, half the strip lit.

| RenderDock says | The strip shows |
|---|---|
| Rendering, 40% | The first 40% of the lights, green |
| Working, with no percentage (agents only) | All lights, blue |
| Something is waiting for you | All lights, amber |
| Something failed | All lights, red |
| Done | All lights, green, for the few minutes RenderDock says "done" |
| Nothing going on | The strip is handed back to WLED, and whatever effect it was running carries on |

```bash
python3 wled_progress.py 192.168.1.50
```

Stop it with Ctrl-C and the strip is handed back.

It needs RenderDock's **Local API** switched on (menu-bar icon → Local API), Python 3.8 or later, and nothing else. RenderDock itself still makes no connection to your network: this script does, to the one address you give it.

## Trying it without a strip

```bash
python3 wled_progress.py --self-test
```

runs it against stand-ins for both ends and checks every request it would send.

## What has and has not been checked

- **Checked**: the self-test above. The requests are the ones WLED's documentation describes: `POST /json/state` with `{"seg":{"i":[start, stop, "RRGGBB", …]}}`, the strip switched on in a request of its own first, and `{"seg":{"frz":false}}` to hand it back.
- **Not checked: a real strip.** The author does not have one. In particular, WLED's documentation gives the range form by example only, so whether `stop` is the last light or the one after it is read from that example; if your bar is one light short or long, that is where to look.

The same can be done with no script at all, through [MQTT](../../docs/MQTT.md) and Home Assistant.
