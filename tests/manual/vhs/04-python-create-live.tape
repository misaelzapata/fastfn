Output "/tmp/fastfn-vhs-04-python-create.gif"

Require ./bin/fastfn
Require curl
Require jq
Require nvim
Require python3

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
Type "python3 --version"
Enter
Type "rm -rf /tmp/f4 && mkdir -p /tmp/f4/functions/python/pyhello"
Enter
Type "nvim /tmp/f4/functions/python/pyhello/handler.py"
Enter
Sleep 600ms
Type "i"
Type "import json\n\ndef handler(event):\n    q = event.get('query') or {}\n    name = q.get('name', 'ana')\n    nums = [1, 2, 3]\n    return {\n        'status': 200,\n        'headers': {'content-type': 'application/json'},\n        'body': json.dumps({'ok': True, 'name': name, 'nums': nums}),\n    }\n"
Escape
Type ":wq"
Enter
Type "FN_HOST_PORT=8094 ./bin/fastfn dev --native /tmp/f4/functions >/tmp/f4/dev.log 2>&1 &"
Enter
Type "sleep 3"
Enter
Type "curl -i 'http://127.0.0.1:8094/pyhello?name=misa' | sed -n '1,20p'"
Enter
Type "pkill -f '/bin/fastfn dev --native /tmp/f4/functions'"
Enter
