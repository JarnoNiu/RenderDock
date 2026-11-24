# A Stream Deck key

`io.github.jarnoniu.renderdock.sdPlugin` is a Stream Deck plugin with one action, **Render progress**: a key that shows a ring and the percentage of the render in front. Amber with `!` when something is waiting for you, red when something failed, a tick when the queue is done.

It reads RenderDock's **Local API** on this computer, so that has to be on (menu-bar icon → Local API). It is plain Node.js with nothing to install and nothing to build.

## **Not run on a Stream Deck yet**

The author has no Stream Deck. The plugin follows Elgato's published plugin protocol and manifest reference, and it passes its own test:

```bash
node io.github.jarnoniu.renderdock.sdPlugin/plugin.js --self-test
```

which plays the Stream Deck application's part: it takes the plugin's connection, checks how it registers, puts a key up, and reads the pictures it is sent as the state changes. What that cannot show is whether the real application accepts the manifest as written and draws the picture as meant. If you try it, a report either way is welcome, and this notice goes when someone has.

## Installing it

Copy the `.sdPlugin` folder into the Stream Deck application's plugins folder and restart the application; the action then appears under "RenderDock". Elgato's documentation says where that folder is for your version.

## What is in it

| File | What it is |
|---|---|
| `manifest.json` | What the application reads: one action, for keys, on macOS |
| `plugin.js` | The plugin. Speaks the WebSocket protocol to the application itself, so it does not depend on which Node.js the application ships |
| `imgs/` | The plugin's icon (drawn by RenderDock), the action's icon, and the key's picture before the first reading |
