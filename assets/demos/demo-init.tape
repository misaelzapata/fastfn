Output assets/demos/demo-init.mp4
Output assets/demos/demo-init.gif

# -- Visual chrome --
Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 16
Set Width 1200
Set Height 700
Set Padding 25
Set Margin 20
Set MarginFill "#000000"
Set WindowBar Colorful
Set WindowBarSize 40
Set BorderRadius 10
Set Framerate 30
Set CursorBlink false

Set Theme { "name": "FastFN Night", "black": "#0a0e14", "red": "#f7768e", "green": "#9ece6a", "yellow": "#e0af68", "blue": "#7aa2f7", "purple": "#bb9af7", "cyan": "#73daca", "white": "#c0caf5", "brightBlack": "#565f89", "brightRed": "#f7768e", "brightGreen": "#9ece6a", "brightYellow": "#e0af68", "brightBlue": "#7aa2f7", "brightPurple": "#bb9af7", "brightCyan": "#73daca", "brightWhite": "#c0caf5", "background": "#0a0e14", "foreground": "#a9b1d6", "selectionBackground": "#283457", "cursorAccent": "#a9b1d6", "cursor": "#c0caf5" }

# -- Invisible setup: start server early so it's ready --
Hide
Type `export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"`
Enter
Type `export FN_HOST_PORT=8000`
Enter
Type `export STARSHIP_CONFIG="$HOME/.config/starship.toml"`
Enter
Type `eval "$(starship init bash)"`
Enter
Type `alias ls='eza --icons --group-directories-first'`
Enter
Type `alias ll='eza -la --icons --group-directories-first --git'`
Enter
Type `alias cat='bat --style=auto --paging=never --theme=base16'`
Enter
# Create project and start server NOW so it's warm by curl time
Type `export HOME=/tmp/demohome && mkdir -p $HOME`
Enter
Type `cd /tmp && rm -rf my-api && mkdir my-api && cd my-api && git init -q`
Enter
Type `fastfn init hello -t python > /dev/null 2>&1`
Enter
Type `fastfn init users -t node > /dev/null 2>&1`
Enter
Type `nohup fastfn dev --native . > /tmp/fn.log 2>&1 &`
Enter
Type `disown`
Enter
# Clean up so init commands will run again visibly
Type `rm -rf hello users`
Enter
Sleep 5s
Type `printf '\033c'`
Enter
Sleep 500ms
Show

# =============================================
# SECTION 1: Init Python function
# =============================================
Sleep 1000ms

Set TypingSpeed 65ms
Type "fas"
Set TypingSpeed 35ms
Type "tfn"
Sleep 120ms
Type " init"
Sleep 280ms
Type " hel"
Set TypingSpeed 45ms
Type "lo"
Sleep 350ms
Set TypingSpeed 55ms
Type " -t "
Sleep 150ms
Type "pyth"
Set TypingSpeed 30ms
Type "on"
Sleep 400ms
Enter
Sleep 2200ms

# =============================================
# SECTION 2: Init Node function
# =============================================
Sleep 500ms
Set TypingSpeed 40ms
Type "fastfn init"
Sleep 200ms
Type " us"
Set TypingSpeed 50ms
Type "re"
Backspace 2
Sleep 80ms
Set TypingSpeed 35ms
Type "ers"
Sleep 300ms
Type " -t node"
Sleep 350ms
Enter
Sleep 2000ms

# =============================================
# SECTION 3: Show Python handler
# =============================================
Sleep 500ms
Set TypingSpeed 55ms
Type "cat "
Sleep 100ms
Set TypingSpeed 35ms
Type "hello/ha"
Set TypingSpeed 25ms
Type "ndler.py"
Sleep 250ms
Enter
Sleep 3500ms

# =============================================
# SECTION 4: Show Node handler
# =============================================
Sleep 400ms
Set TypingSpeed 40ms
Type "cat users"
Set TypingSpeed 30ms
Type "/handler.js"
Sleep 200ms
Enter
Sleep 3500ms

# =============================================
# SECTION 5: fastfn dev --native . (cosmetic)
# Show the startup output from the log
# =============================================
Sleep 500ms

Set TypingSpeed 50ms
Type "fast"
Set TypingSpeed 35ms
Type "fn dev"
Sleep 200ms
Set TypingSpeed 40ms
Type " --native ."
Sleep 400ms

# User presses Enter but we actually show the pre-recorded log
Hide
Ctrl+U
Type "head -12 /tmp/fn.log"
Show
Enter

Sleep 3500ms

# =============================================
# SECTION 6: curl Python endpoint - REAL
# =============================================
Sleep 600ms

Set TypingSpeed 50ms
Type "curl"
Sleep 150ms
Set TypingSpeed 35ms
Type " -s"
Sleep 200ms
Type " localhost"
Set TypingSpeed 28ms
Type ":8000/hello"
Sleep 180ms
Set TypingSpeed 40ms
Type "?name="
Sleep 250ms
Set TypingSpeed 35ms
Type "FastFN"
Sleep 200ms
Type " | jq ."
Sleep 350ms
Enter
Sleep 2500ms

# =============================================
# SECTION 7: curl Node endpoint - REAL
# =============================================
Sleep 400ms
Set TypingSpeed 45ms
Type "curl"
Sleep 100ms
Set TypingSpeed 30ms
Type " -s localhost:8000"
Set TypingSpeed 35ms
Type "/users"
Sleep 180ms
Set TypingSpeed 40ms
Type "?role="
Sleep 200ms
Set TypingSpeed 35ms
Type "admin"
Sleep 200ms
Type " | jq ."
Sleep 300ms
Enter
Sleep 4000ms

# =============================================
# SECTION 8: Project structure
# =============================================
Sleep 400ms
Set TypingSpeed 50ms
Type "ll"
Sleep 180ms
Enter
Sleep 1500ms

Set TypingSpeed 45ms
Type "ll h"
Set TypingSpeed 30ms
Type "ello/"
Sleep 200ms
Enter
Sleep 1500ms

Set TypingSpeed 45ms
Type "ll u"
Set TypingSpeed 30ms
Type "sers/"
Sleep 200ms
Enter
Sleep 1800ms

# Cleanup: kill the server so port is free
Hide
Type `kill -9 $(lsof -ti:8000) 2>/dev/null`
Enter
Sleep 500ms
Show
