Output "/tmp/fastfn-vhs-02-node-list-id1.gif"

Require ./bin/fastfn
Require curl
Require jq
Require nvim
Require node

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
Type "node -v"
Enter
Type "rm -rf /tmp/f2 && mkdir -p /tmp/f2"
Enter
Type "cp -R examples/functions/next-style /tmp/f2/functions"
Enter
Type "nvim /tmp/f2/functions/users/index.js"
Enter
Sleep 600ms
Type "ggVGd"
Type "i"
Type "const users = [\n  { id: 1, name: 'Ana' },\n  { id: 2, name: 'Luis' },\n  { id: 3, name: 'Rosa' },\n]\n\nexports.handler = async (event) => {\n  const q = event.query || {}\n  const id = Number(q.id ?? 1)\n  const found = users.find((u) => u.id === id) || null\n  return {\n    status: found ? 200 : 404,\n    headers: { 'content-type': 'application/json' },\n    body: JSON.stringify({ id, found, users }),\n  }\n}\n"
Escape
Type ":wq"
Enter
Type "FN_HOST_PORT=8092 ./bin/fastfn dev --native /tmp/f2/functions >/tmp/f2/dev.log 2>&1 &"
Enter
Type "sleep 3"
Enter
Type "curl -s 'http://127.0.0.1:8092/users?id=1' | jq '{id,found,users}'"
Enter
Type "curl -s 'http://127.0.0.1:8092/html?name=Ana' | sed -n '1,12p'"
Enter
Type "pkill -f '/bin/fastfn dev --native /tmp/f2/functions'"
Enter
