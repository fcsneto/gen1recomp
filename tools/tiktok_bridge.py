#!/usr/bin/env python3
"""Translate exact TikTok LIVE chat commands into local Gen1 input requests.

This program deliberately never opens a listening socket. It connects outward
to TikTok and sends authenticated requests only to the game's loopback-only
receiver at 127.0.0.1.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from collections.abc import Mapping
from dataclasses import dataclass, field

import httpx
from TikTokLive import TikTokLiveClient
from TikTokLive.events import CommentEvent, ConnectEvent


COMMANDS: Mapping[str, str] = {
    "up": "up", "cima": "up",
    "down": "down", "baixo": "down",
    "left": "left", "esquerda": "left",
    "right": "right", "direita": "right",
    "a": "a", "confirmar": "a",
    "b": "b", "voltar": "b",
    "start": "start", "menu": "start",
    "select": "select",
}


def parse_command(comment: str, prefix: str) -> str | None:
    """Return an input action only for a complete, prefixed chat command."""
    text = comment.strip().casefold()
    if not text.startswith(prefix.casefold()):
        return None
    return COMMANDS.get(text[len(prefix):].strip())


@dataclass
class RateLimiter:
    global_interval: float
    user_interval: float
    _next_global: float = 0.0
    _last_by_user: dict[str, float] = field(default_factory=dict)

    def allow(self, user_id: str, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        if now < self._next_global:
            return False
        if now - self._last_by_user.get(user_id, float("-inf")) < self.user_interval:
            return False
        self._next_global = now + self.global_interval
        self._last_by_user[user_id] = now
        # Bound memory even during unusually large livestreams.
        if len(self._last_by_user) > 4096:
            cutoff = now - max(self.user_interval * 2, 60.0)
            self._last_by_user = {
                key: seen for key, seen in self._last_by_user.items() if seen >= cutoff
            }
        return True


class GameReceiver:
    def __init__(self, token: str, port: int, duration_ms: int, dry_run: bool) -> None:
        self._token = token
        self._duration_ms = duration_ms
        self._dry_run = dry_run
        self._url = f"http://127.0.0.1:{port}/input"
        self._client = httpx.Client(timeout=httpx.Timeout(2.0), trust_env=False)

    def send(self, action: str) -> bool:
        if self._dry_run:
            print(f"[dry-run] action={action}", flush=True)
            return True
        try:
            response = self._client.post(
                self._url,
                headers={"X-Remote-Token": self._token},
                json={"action": action, "duration_ms": self._duration_ms},
            )
        except httpx.HTTPError as error:
            print(f"[receiver] request failed: {error}", file=sys.stderr, flush=True)
            return False
        if response.status_code != 202:
            print(
                f"[receiver] rejected command: HTTP {response.status_code} {response.text}",
                file=sys.stderr,
                flush=True,
            )
            return False
        return True

    def close(self) -> None:
        self._client.close()


def run_client(args: argparse.Namespace) -> None:
    limiter = RateLimiter(args.global_cooldown, args.user_cooldown)
    receiver = GameReceiver(args.token, args.port, args.duration_ms, args.dry_run)
    try:
        while True:
            client = TikTokLiveClient(unique_id=args.unique_id)

            @client.on(ConnectEvent)
            async def on_connect(event: ConnectEvent) -> None:
                print(f"[connected] TikTok LIVE @{event.unique_id}", flush=True)

            @client.on(CommentEvent)
            async def on_comment(event: CommentEvent) -> None:
                action = parse_command(event.content, args.prefix)
                if action is None:
                    return
                user = getattr(event.user, "unique_id", None) or "anonymous"
                if not limiter.allow(str(user)):
                    return
                if receiver.send(action):
                    print(f"[queued] @{user}: {action}", flush=True)

            try:
                client.run()
            except KeyboardInterrupt:
                return
            except Exception as error:  # TikTok changes its webcast protocol frequently.
                print(f"[tiktok] connection ended: {error}", file=sys.stderr, flush=True)
            print(f"[tiktok] reconnecting in {args.reconnect_seconds}s", flush=True)
            time.sleep(args.reconnect_seconds)
    finally:
        receiver.close()


def self_test() -> None:
    assert parse_command(" !DIREITA ", "!") == "right"
    assert parse_command("!cima agora", "!") is None
    assert parse_command("direita", "!") is None
    limiter = RateLimiter(global_interval=0.1, user_interval=0.8)
    assert limiter.allow("one", now=1.0)
    assert not limiter.allow("two", now=1.05)
    assert not limiter.allow("one", now=1.2)
    assert limiter.allow("two", now=1.8)
    print("TikTok bridge self-test OK")


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unique-id", default=os.getenv("TIKTOK_LIVE_UNIQUE_ID"),
                        help="TikTok handle to watch, with or without @")
    parser.add_argument("--token", default=os.getenv("POKEPORT_REMOTE_TOKEN"),
                        help="same secret used to start the game")
    parser.add_argument("--port", type=int, default=int(os.getenv("POKEPORT_REMOTE_PORT", "38101")))
    parser.add_argument("--duration-ms", type=int, default=120)
    parser.add_argument("--prefix", default="!")
    parser.add_argument("--global-cooldown", type=float, default=0.125)
    parser.add_argument("--user-cooldown", type=float, default=0.8)
    parser.add_argument("--reconnect-seconds", type=float, default=10.0)
    parser.add_argument("--dry-run", action="store_true", help="read chat but do not control the game")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return args
    if not args.unique_id:
        parser.error("--unique-id (or TIKTOK_LIVE_UNIQUE_ID) is required")
    if not args.token:
        parser.error("--token (or POKEPORT_REMOTE_TOKEN) is required")
    if not 1024 <= args.port <= 65535:
        parser.error("--port must be 1024 through 65535")
    if not 1 <= args.duration_ms <= 500:
        parser.error("--duration-ms must be 1 through 500")
    if not args.prefix.strip():
        parser.error("--prefix cannot be empty")
    if args.global_cooldown < 0 or args.user_cooldown < 0 or args.reconnect_seconds <= 0:
        parser.error("cooldowns must be non-negative and reconnect time must be positive")
    return args


if __name__ == "__main__":
    parsed = arguments()
    if parsed.self_test:
        self_test()
    else:
        run_client(parsed)
