Output "/tmp/fastfn-vhs-03-rust-health.gif"

Require ./bin/fastfn
Require curl
Require jq
Require rustc
Require cargo

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 18
Set Width 1080
Set Height 680
Set Padding 18
Set LineHeight 1.15
Set BorderRadius 12
Set WindowBar Colorful
Set WindowBarSize 28
Set Framerate 18
Set TypingSpeed 60ms
Set Theme "TokyoNightStorm"

Type "pwd"
Enter
Type "rust -V"
Enter
Type "rustc -V"
Enter
Type "cargo -V"
Enter
Type "rm -rf /tmp/f3 && mkdir -p /tmp/f3"
Enter
Type "cp -R examples/functions/next-style /tmp/f3/functions"
Enter
Type "FN_RUNTIMES=python,node,lua,rust FN_HOST_PORT=8093 ./bin/fastfn dev --native /tmp/f3/functions >/tmp/f3/dev.log 2>&1 &"
Enter
Type "sleep 3"
Enter
Type "curl -s http://127.0.0.1:8093/_fn/health | jq '.runtimes | keys'"
Enter
Type "curl -fsS http://127.0.0.1:8093/rust/health | jq ."
Enter
Type "pkill -f '/bin/fastfn dev --native /tmp/f3/functions'"
Enter
