# Synthetic visual demo. From the repo root:
# zig build -Doptimize=ReleaseSafe -Dsilent-input=true --prefix .runs/preview-out
# python3 scripts/demo_player.py --prepare .runs/demo-home
# vhs scripts/player.tape
Output docs/player.gif
Output .runs/player.mp4
Set Shell bash
Set FontFamily "Menlo"
Set FontSize 18
Set Width 1200
Set Height 780
Set Padding 20
Set Framerate 15
Set Theme {"background":"#080808","foreground":"#c5c7d2","black":"#080808","brightBlack":"#606578","green":"#87ffd7","yellow":"#ffd787","cyan":"#87d7ff","white":"#c5c7d2","brightWhite":"#ffffff"}
Set CursorBlink false
Hide
Type 'env -u NO_COLOR HOME="$PWD/.runs/demo-home" XDG_CONFIG_HOME="$PWD/.runs/demo-home/.config" .runs/preview-out/bin/rec play "Northern Lights.wav"'
Enter
Sleep 2s
Show
Sleep 3s
Type "z"
Sleep 3s
Type "v"
Sleep 3s
Type "v"
Sleep 3s
Hide
Type "q"
