#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import urllib.parse


def encode_text(text: str) -> None:
    print(urllib.parse.quote(text))


def validate_response(raw: str, container_mode: bool) -> None:
    try:
        obj = json.loads(raw)
    except Exception as exc:
        print(f"Bad JSON response: {exc}", file=sys.stderr)
        print(raw, file=sys.stderr)
        raise SystemExit(1)

    if obj.get("dry_run") is True:
        if container_mode:
            print("fastfn returned dry_run=true; TELEGRAM_BOT_TOKEN is likely missing in the container.", file=sys.stderr)
        else:
            print(
                "fastfn returned dry_run=true; did you configure TELEGRAM_BOT_TOKEN in node/telegram-send/fn.env.json?",
                file=sys.stderr,
            )
        print(json.dumps(obj, indent=2), file=sys.stderr)
        raise SystemExit(1)

    if obj.get("sent") is not True:
        print("fastfn did not confirm sent=true", file=sys.stderr)
        print(json.dumps(obj, indent=2), file=sys.stderr)
        raise SystemExit(1)

    print("OK: telegram-send reports sent=true")
    print(json.dumps(obj, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    encode = sub.add_parser("encode")
    encode.add_argument("--text", required=True)
    encode.set_defaults(func=lambda args: encode_text(args.text))

    validate = sub.add_parser("validate")
    validate.add_argument("--raw", required=True)
    validate.add_argument("--container-mode", action="store_true")
    validate.set_defaults(func=lambda args: validate_response(args.raw, args.container_mode))
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
