# μDLNA server

Share movies, music, and photos from your Mac with a TV or media player on your
home network. μDLNA server lives in the menu bar and keeps your folder structure intact.

Requires macOS 13 or later. Supports Apple silicon and Intel Macs.

## Install

1. Download the DMG from [GitHub Releases](https://github.com/spyroid/micro-dlna/releases).
2. Open it and drag **microDLNA.app** into **Applications**.
3. Launch μDLNA server. A TV icon appears in the menu bar, next to the clock.

Starting with version 1.0.1, official releases are signed with Developer ID and
notarized by Apple.

## Watch your media

1. Put your media in your Mac's **Movies** folder (`~/Movies`). Nested folders work too.
2. Allow access to your media and local network if macOS asks.
3. Connect your Mac and player to the same local network.
4. Open the player's UPnP/DLNA browser and select **μDLNA server**.
   In VLC, look under **Local Network → Universal Plug'n'Play**.

Keep the app running while watching. Restart it after adding, moving, or deleting
files to refresh the library. Hover over the menu bar icon to see the shared folder.

Supported files: MP4, M4V, MKV, MOV, AVI; MP3, M4A, FLAC, WAV; JPG, JPEG, PNG.
Playback depends on your player's format support: μDLNA server sends the original files
without converting them. Folders and file types have distinct icons and colors
in players that display artwork.

Media is shared without a password. Use μDLNA server on a trusted local network.

## Choose a folder or address

When launched without arguments, μDLNA server shares `~/Movies` and automatically selects
your Mac's local network IPv4 address.

To change these values, quit the app first, then launch it from Terminal:

```sh
open /Applications/microDLNA.app --args "$HOME/Videos" 192.168.1.20
```

Replace the folder with your media folder and the address with your Mac's IPv4
address on your local network. Omit the address to keep automatic selection:

```sh
open /Applications/microDLNA.app --args "$HOME/Videos"
```

## Menu and updates

Click the TV icon for **About**, **Support Development…**, **Check for Updates…**, or **Quit**.
The second menu row shows your media folder; click it to open the folder in Finder.
Long paths are shortened in the menu; hover over the row to see the full path.
Updates are checked automatically and can be installed when you quit the app.

## Support development

Enjoy μDLNA server? [Support development on Ko-fi](https://ko-fi.com/spyroid).
You can also find this link in the app menu and About window.

## License and development

Free to use and share for free. Selling or charging for distribution requires the
author's written permission. See [LICENSE](LICENSE).

Build, test, and release instructions: [DEVELOPMENT.md](DEVELOPMENT.md).
