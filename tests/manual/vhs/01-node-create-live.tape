Output "/tmp/fastfn-vhs-01-node-create.gif"

Require ./bin/fastfn
Require curl
Require jq
Require nvim
Require node
Require rg

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
Type "nod -v"
Enter
Type "node -v"
Enter
Type "env | rg -i '^(fn_|node|shell)' || true"
Enter
Type "rm -rf /tmp/f1 && mkdir -p /tmp/f1/functions"
Enter
Type "FN_HOST_PORT=8091 ./bin/fastfn dev --native /tmp/f1/functions >/tmp/f1/dev.log 2>&1 &"
Enter
Type "sleep 3"
Enter
Type "curl -i http://127.0.0.1:8091/hola | sed -n '1,12p'"
Enter
Type "mkdir -p /tmp/f1/functions/node/hola"
Enter
Type "nvim /tmp/f1/functions/node/hola/handler.js"
Enter
Sleep 600ms
Type "i"
Type "const listt = [1, 2, 3]\n\nexports.handler = async (event) => {\n  const q = event.query || {}\n  const n = Number(q.n ?? li"
Ctrl+N
Type ")\n  return {\n    status: 200,\n    headers: { 'content-type': 'application/json' },\n    body: JSON.stringify({ ok: true, n, listt }),\n  }\n}\n"
Escape
Type ":%s/listt/list/g"
Enter
Type ":wq"
Enter
Type "sleep 1"
Enter
Type "curl -i 'http://127.0.0.1:8091/hola?n=7' | sed -n '1,20p'"
Enter
Type "pkill -f '/bin/fastfn dev --native /tmp/f1/functions'"
Enter
