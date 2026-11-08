# Mitame

**Sharp, Retina-like text on your non-4K external monitor.**

[日本語](README.ja.md)

When you connect a Full HD or QHD monitor to a Mac, text often looks soft or blurry,
because macOS only uses its sharp HiDPI (Retina) rendering on high-resolution screens.
Mitame is a small, free menu bar app that turns on HiDPI for your external monitor with one click.

<p align="center"><img src="docs/images/menu-en.png" width="520" alt="The Mitame menu in the menu bar, with HiDPI turned on and the Looks Like sizes for a Full HD monitor"></p>

*Mitame* (見た目) is Japanese for "how things look". It is a sister app of [Nakami](https://github.com/synchrium/Nakami) ("contents").

> [!NOTE]
> **Mitame is in beta.** It has only been tested on one setup so far (see [Tested setups](#tested-setups)).
> If you try it on another Mac or monitor, please tell us how it went in [Issues](https://github.com/synchrium/Mitame/issues) — it helps a lot.

## Features

- **One click** — choose **HiDPI** in the menu bar, and your monitor switches in a few seconds
- **Choose how big things look** — seven sizes based on your monitor's own resolution and shape (16:9, 16:10, 21:9, …)
- **Comes back by itself** — after sleep, restarting your Mac, or unplugging and plugging in the cable
- **No flicker after sleep** — Mitame leaves the screen alone while the Mac sleeps and lets macOS restore it
- **Open at Login**
- **More than one monitor?** Choose which monitor to make HiDPI
- **Quit to undo** — when you quit Mitame, your monitor goes back to how it was
- **English and Japanese**
- **Works offline** — Mitame does not connect to the internet and does not collect any data

## How it works

Mitame creates an invisible HiDPI "virtual display" that is twice the size you choose,
and mirrors your monitor onto it. macOS draws everything at 2× on the virtual display,
and the graphics chip shrinks the picture to fit your monitor — so text comes out sharp.
This is the same technique that [BetterDisplay](https://github.com/waydabber/BetterDisplay) uses for its HiDPI mirroring.

The core of Mitame comes from [hidpi-mirror](https://github.com/pasky/hidpi-mirror) by Petr Baudis.
Mitame adds a menu bar app around it.

> [!IMPORTANT]
> Mitame uses a **private macOS API** (`CGVirtualDisplay`) to create the virtual display.
> This is why Mitame is not on the Mac App Store, and a future macOS update could stop it from working.
> If that happens, quit Mitame and your monitor goes back to normal.

## Requirements

- macOS 14 Sonoma or later
- A Mac with Apple silicon or an Intel processor
- An external monitor that is **not** 4K or higher (4K and 5K monitors are already HiDPI in macOS, so Mitame is not needed)

### Tested setups

| Mac | macOS | Monitor | Result |
| --- | --- | --- | --- |
| MacBook Air (M1) | 27.2 | 24" Full HD (1920 × 1080, 16:9), USB-C to HDMI | Works, including sleep, restart, unplugging, and lid closed |

Not tested yet: macOS 14–26, Intel Macs, QHD / 16:10 / ultrawide monitors, two or more monitors, DisplayLink adapters.
If you try one of these, please [let us know](https://github.com/synchrium/Mitame/issues).

## Install

1. Download `Mitame-x.y.zip` from the [latest release](https://github.com/synchrium/Mitame/releases/latest).
2. Double-click the zip file to extract `Mitame.app`.
3. **Drag `Mitame.app` to the Applications folder in the Finder.**
   (Please move it with the Finder. If you open it without moving it, macOS runs it from a temporary location.)

### Opening Mitame for the first time

Mitame is free and is not notarized by Apple (that requires a paid Apple Developer membership),
so macOS asks you to confirm before opening it the first time.

1. Double-click Mitame in the Applications folder. You will see **"Mitame" Not Opened**. Click **Done**.
   (Do not click "Move to Trash".)
2. Open **System Settings → Privacy & Security** and scroll down to the **Security** section.
3. Next to **"Mitame" was blocked to protect your Mac**, click **Open Anyway**.
4. Click **Open Anyway** again, and enter your password (or use Touch ID).

After this, Mitame opens normally. It appears in the menu bar (not in the Dock).

<details>
<summary>Using Terminal instead</summary>

If you are comfortable with Terminal, this command does the same thing as the steps above:

```sh
xattr -dr com.apple.quarantine /Applications/Mitame.app
```

</details>

### Updating to a new version

Quit Mitame, and replace `Mitame.app` in the Applications folder with the new one.
**macOS treats each new version as a new app, so you need to do the steps in
[Opening Mitame for the first time](#opening-mitame-for-the-first-time) again.**

## How to use

Click the monitor icon in the menu bar.

| Menu | What it does |
| --- | --- |
| **HiDPI** | Turns HiDPI on or off for your monitor |
| **Looks Like** | How big things look. Bigger numbers fit more on the screen (smaller text). "Same as Monitor" keeps the size you have now, only sharper |
| **Monitor** | Shown when two or more monitors are connected. Chooses which one to make HiDPI |
| **Rebuild** | Creates the virtual display again. Try this if the screen ever looks wrong |
| **Open at Login** | Starts Mitame when you log in. If HiDPI was on, it turns on again |

Mitame remembers your choices. If you unplug the monitor while HiDPI is on, Mitame waits and turns it back on when you plug it in.

## If something goes wrong

- **Quit Mitame** (menu bar icon → **Quit Mitame**). Your monitor goes back to its normal resolution.
- If the menu bar icon is not visible, open **Activity Monitor**, select **Mitame**, and click the ✕ button to quit it.
  The virtual display goes away together with Mitame.
- You can always check or change your monitor in **System Settings → Displays**.

## Feedback

Mitame is in beta, and your feedback shapes version 1.0. Please open an [issue](https://github.com/synchrium/Mitame/issues) for:

- Whether it worked on your Mac and monitor (please include the Mac model, macOS version, and monitor resolution)
- Bugs and anything that felt confusing
- What you think of the icon 🙂

## Build from source

You need Xcode 27 or later.

1. Clone this repository and open `Mitame.xcodeproj`.
2. In **Signing & Capabilities**, choose your own team for the Mitame target.
3. Press ⌘R.

To make the same build as the releases (ad-hoc signed, Universal, with no personal information in the app), run:

```sh
Scripts/build-dist.sh
```

The virtual display code is in `Mitame/Engine/MitameEngine.m`, based on `hidpi-mirror.m`.

## Thanks

Huge thanks to **Petr Baudis** for [hidpi-mirror](https://github.com/pasky/hidpi-mirror).
Its careful handling of sleep, reconnects, and WindowServer quirks is what makes Mitame reliable.

## License

[MIT License](LICENSE). Mitame includes code from hidpi-mirror (MIT License, © 2026 Petr Baudis); its license is included in [LICENSE](LICENSE).

Mitame is provided as is, without warranty of any kind. The author is not liable for any damages arising from its use.
See [LICENSE](LICENSE) for details.
