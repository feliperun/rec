# Regenerates docs/demo.gif — the README demo. Run from the repo root:
#   vhs scripts/demo.tape
# The fixtures are synthetic ffmpeg tones in a scratch $HOME (/tmp/rec-demo);
# nothing of yours is recorded or shown. `rec record` needs the microphone:
# scripts/demo_record.sh plays the short fixture over the speakers while it
# captures.
Output docs/demo.gif

Set Shell zsh
Set FontSize 21
Set Width 1150
Set Height 660
Set Theme "Dracula"
Set Padding 42
Set CursorBlink false
Set PlaybackSpeed 1.2
Set TypingSpeed 60ms

Hide
Type 'export PS1="$ " PROMPT="$ " PATH=$PWD/zig-out/bin:$PATH && export HOME=/tmp/rec-demo && rm -rf /tmp/rec-demo && mkdir -p $HOME/recordings && ffmpeg -hide_banner -loglevel error -f lavfi -i "aevalsrc=0.55*sin(2*PI*180*t)*(0.5+0.5*sin(2*PI*0.7*t))+0.22*sin(2*PI*1150*t)*(0.5+0.5*sin(2*PI*1.9*t)):s=48000:d=6" -ar 48000 -ac 1 -c:a aac -b:a 96k -f mp4 $HOME/recordings/20260904-093001.m4a && ffmpeg -hide_banner -loglevel error -f lavfi -i "aevalsrc=0.55*sin(2*PI*180*t)*(0.5+0.5*sin(2*PI*0.7*t))+0.22*sin(2*PI*1150*t)*(0.5+0.5*sin(2*PI*1.9*t)):s=48000:d=12" -ar 48000 -ac 1 -c:a aac -b:a 96k -f mp4 $HOME/recordings/20260904-090115.m4a && printf "%s\n" "---" "duration: 12.0" "language: en-US" "---" "Speaker 1: Welcome to rec, a terminal meeting recorder." "Speaker 2: Play it back, cut the noise out, transcribe in one key." > $HOME/recordings/20260904-090115.md && clear' Enter
Sleep 1.5s
Show

# Record: the short fixture plays over the speakers while the mic captures.
Type "bash scripts/demo_record.sh" Enter
Sleep 6.4s

# The new recording is in the library.
Type "rec list" Enter
Sleep 1.6s

# Play the long fixture by name: transcript first, then the live view.
Type "rec play 20260904-090115.m4a" Enter
Sleep 2.8s
Type " "
Sleep 0.9s
Left
Left
Sleep 0.7s
Right
Right
Right
Right
Sleep 0.7s
Type "i"
Sleep 0.6s
Right
Right
Type "o"
Sleep 1.2s
Type " "
Sleep 0.9s
Delete
Sleep 1.2s
Enter
Sleep 2s
Type "q"
Sleep 1.3s

# The cut shows in the library.
Type "rec list" Enter
Sleep 2s
