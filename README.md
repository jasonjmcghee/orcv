# <img src="./orcv/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="64" height="64" align="center"> orcv

orcv (ork-vee) is a macos app that lets you create virtual displays in an infinite canvas (zoom/pan), arrange them, create "savepoints", teleport windows or your mouse to or from them, or fullscreen one, all in a picture-in-picture style overlay you can keep on your main display.

_These are real / recognized displays by macos, which are automatically arranged based on how you arrange them in the canvas, just like if you had a bunch of monitors on your desk._

<img width="896" height="559" alt="Screenshot 2026-03-01 at 2 40 12 PM" src="https://github.com/user-attachments/assets/f6e084dd-71a0-45a8-bd29-957302cae525" />

_Yes this is a screenshot of me deciding I wanted a recursive screenshot

In today's world, long-running tasks that you have to manage have visual aspects. That doesn't work well with the terminal. tmux and Zellij and friends have a lot of great attributes, but I had yet to use something that checked all my boxes.

The first version of this came together pretty quickly, but I've spent more time trying to nail the UX and just trying things out until they felt "right" than actually implementing the software itself. I just redid things until they never hitched and felt natural. 

It's built it in a way that it's very cheap to render your many desktops.

I encourage you to just, try it out to get a feel for it.

# Demo

![Demo]()

# Features / How To

The main features / user flows are:
- open a virtual desktop that you can freely interact with (`cmd+n` by default - hover over one and hit `cmd+w` to close)
- teleport your mouse or a window to a desktop by hovering it over a tile and then hitting "teleport" (`cmd+cmd` by default)
- create "savepoints" that save the orcv PiP window location and size, and canvas pan and zoom that you can recall (`cmd+0-9` to save and `0-9` to recall by default).
- "jump to" a specific or the next/prev desktop (`option+0-9` and `tab` / `shift+tab` respectively by default)
- undo / redo history for canvas interactions like moving desktops, arranging, or moving or resizing the orcv PiP window itself
- navigation forward / back for all jumps and navigations
- you can resize the canvas or stretch the canvas (hold `ctrl` by default to resize instead of stretch, can be swapped via toggle)
- fullscreen by hovering over a tile and hitting the shortcut (`shift+shift` by default, `cmd+cmd` to exit)
- freely move the window by holding the move shortcut (`space` by default) while hovering over any part of the orcv PiP window

# Install

Download from [Releases](https://github.com/jasonjmcghee/orcv/releases) (created with auditable Github Action).

Feel free to build yourself using Xcode or `./build.sh`.

Either way - open the `dmg` and drag the "orcv" to "Applications" shortcut area.

# Getting Started

On first launch you are asked to give permission to screen recording and accessibility.

These are required for this app to work as it is observing virtual displays and moving your mouse on your behalf.

Nothing ever leaves your computer, all the source is available and clear - I always encourage you to be skeptical of everything you run and very much encourage you to build the app yourself - it is easy. I also sign builds for this app under my name and the releases are built with Github Actions - the source of which is also available to read.

Now that you have permissions setup...

Just want to give a heads up that opening and closing hitches takes a half a second or so as macos is creating / closing a bunch of desktops at once. I've improved this a fair amount, but if anyone has thoughts / ideas, I'd love to hear them.

As a last note, things do take a _bit_ of getting used to, so the patterns feel natural, but I've become quickly productive with this setup.

## After Permissions

Make sure to restart as needed - you should no longer see the permissions window.

With that out of the way... 

You'll see a window open with no traffic lights / title bar.

Hit `cmd+n` or choose "new display" from the menu. Create a few if you want.

Try hitting `cmd+cmd` in quick succession while hovering over it to teleport inside and then again to teleport back out.

_You can change all these shortcuts!_

You can zoom in (pinch or `cmd+scroll`) / pan (two fingers swipe gesture) to nicely center it or just hit `option+1` and / or you can resize the window or canvas (hold `ctrl` while resizing) to fit it.

You can move the entire orcv window just by dragging anywhere inside of it (other than over the desktop inside) or using the "move" shortcut.

I like to put it on the right side - and make it kind of long so i can see 2-3 desktops at once.

You can enable auto-arrange (and drag things around) or hit arrange once according to your preferences.

Once you have things nicely arranged, you can start moving windows as desired by dragging them over a tile and while still holding click down, hit `cmd+cmd` in quick succession which will teleport the window inside the desktop (this can lag the first time, but generally after).

You can hit `cmd+cmd` again to teleport out. You can also hover on a desktop and hit `shift+shift` to fullscreen temporarily and work as desired inside the desktop, then hit `cmd+cmd` to close it.

Once you're comfortable you can start creating savepoints - you can hit `cmd+1` at any time to "snapshot" however the window / canvas / desktops inside are arranged/panned/sized etc. and wherever the window is on your screen. At any time you can recall this by hitting `1`.

If you move anything or resize or whatever and want to undo, just hit `cmd+z` (and redo with `cmd+shift+z`).

If you get lost or want to "go back" to somewhere, you can hit `cmd+[` (and forward with `cmd+]`)

# Shortcut Keys / Configuration

I tried to build everything in a way that you can do things naturally and change shortcuts to meet your needs.

Just open "Shortcuts" menu and you can go to the actions and hit "record" and hit the keys to customize them.

There are a number of other preference-y things in the menus you can change.
