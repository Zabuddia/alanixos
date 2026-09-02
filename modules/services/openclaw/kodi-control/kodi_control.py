#!/usr/bin/env python3
"""Small, structured Kodi JSON-RPC client for OpenClaw."""

import argparse
import difflib
import json
import re
import subprocess
import sys
import time
from typing import Any
from urllib.parse import urlparse


class KodiError(RuntimeError):
    pass


def emit(value: Any) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def normalized(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


class KodiClient:
    def __init__(self, host: str, url: str, connect_timeout: int) -> None:
        self.host = host
        self.url = url
        self.connect_timeout = connect_timeout
        self.request_id = 0

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        self.request_id += 1
        payload: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": self.request_id,
            "method": method,
        }
        if params is not None:
            payload["params"] = params

        remote_command = (
            f"curl -sS --max-time 15 -X POST {self.url} "
            "-H 'Content-Type: application/json' --data-binary @-"
        )
        command = [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            f"ConnectTimeout={self.connect_timeout}",
            self.host,
            remote_command,
        ]
        completed = subprocess.run(
            command,
            input=json.dumps(payload, separators=(",", ":")),
            text=True,
            capture_output=True,
            timeout=self.connect_timeout + 20,
            check=False,
        )
        if completed.returncode != 0:
            detail = completed.stderr.strip() or f"exit status {completed.returncode}"
            raise KodiError(f"Kodi transport failed: {detail}")
        try:
            response = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise KodiError("Kodi returned invalid JSON") from error
        if "error" in response:
            error = response["error"]
            raise KodiError(
                f"Kodi {method} failed: {error.get('message', 'unknown error')}"
                f" ({error.get('code', 'no code')})"
            )
        return response.get("result")


def choose(items: list[dict[str, Any]], query: str, label_key: str) -> dict[str, Any]:
    query_key = normalized(query)
    if not query_key:
        raise KodiError("A non-empty search value is required")

    exact = [item for item in items if normalized(str(item.get(label_key, ""))) == query_key]
    if len(exact) == 1:
        return exact[0]

    contained = [
        item
        for item in items
        if query_key in normalized(str(item.get(label_key, "")))
        or normalized(str(item.get(label_key, ""))) in query_key
    ]
    if len(contained) == 1:
        return contained[0]

    ranked = sorted(
        items,
        key=lambda item: difflib.SequenceMatcher(
            None, query_key, normalized(str(item.get(label_key, "")))
        ).ratio(),
        reverse=True,
    )
    if ranked:
        best_score = difflib.SequenceMatcher(
            None, query_key, normalized(str(ranked[0].get(label_key, "")))
        ).ratio()
        second_score = (
            difflib.SequenceMatcher(
                None, query_key, normalized(str(ranked[1].get(label_key, "")))
            ).ratio()
            if len(ranked) > 1
            else 0.0
        )
        if best_score >= 0.72 and best_score - second_score >= 0.08:
            return ranked[0]

    candidates = [str(item.get(label_key, "")) for item in ranked[:5]]
    raise KodiError(
        "No unambiguous match. Candidates: " + ", ".join(candidates)
        if candidates
        else "No matching Kodi items were found"
    )


def movies(client: KodiClient) -> list[dict[str, Any]]:
    result = client.call(
        "VideoLibrary.GetMovies",
        {"properties": ["title", "year", "resume"], "sort": {"method": "title"}},
    )
    return result.get("movies", []) if isinstance(result, dict) else []


def channels(client: KodiClient) -> list[dict[str, Any]]:
    group_result = client.call("PVR.GetChannelGroups", {"channeltype": "tv"})
    groups = group_result.get("channelgroups", []) if isinstance(group_result, dict) else []
    all_channels: dict[int, dict[str, Any]] = {}
    for group in groups:
        result = client.call(
            "PVR.GetChannels", {"channelgroupid": group["channelgroupid"]}
        )
        for channel in result.get("channels", []) if isinstance(result, dict) else []:
            all_channels[channel["channelid"]] = channel
    return sorted(all_channels.values(), key=lambda item: str(item.get("label", "")))


def current(client: KodiClient) -> dict[str, Any]:
    players = client.call("Player.GetActivePlayers") or []
    if not players:
        return {"active": False, "players": []}
    current_players = []
    for player in players:
        player_id = player["playerid"]
        item = client.call("Player.GetItem", {"playerid": player_id})
        properties = client.call(
            "Player.GetProperties",
            {
                "playerid": player_id,
                "properties": ["percentage", "time", "totaltime", "speed"],
            },
        )
        current_players.append(
            {
                "playerid": player_id,
                "type": player.get("type"),
                "item": item.get("item") if isinstance(item, dict) else item,
                "properties": properties,
            }
        )
    return {"active": True, "players": current_players}


def active_video_player(client: KodiClient) -> int:
    players = client.call("Player.GetActivePlayers") or []
    for player in players:
        if player.get("type") == "video":
            return int(player["playerid"])
    raise KodiError("Kodi has no active video player")


def wait_for_active_player(
    client: KodiClient, player_type: str, timeout: float = 8.0
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_state: dict[str, Any] = {"active": False, "players": []}
    while time.monotonic() < deadline:
        last_state = current(client)
        if any(
            player.get("type") == player_type
            and (player.get("properties") or {}).get("speed", 0) != 0
            for player in last_state.get("players", [])
        ):
            return last_state
        time.sleep(0.25)
    raise KodiError(f"Kodi did not start an active {player_type} player")


def read_audio_urls() -> list[str]:
    try:
        value = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        raise KodiError("Audio URL input must be a JSON array") from error
    if not isinstance(value, list) or not value:
        raise KodiError("At least one audio URL is required")
    if len(value) > 1000:
        raise KodiError("Audio playlists are limited to 1000 URLs")
    urls: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise KodiError("Every audio playlist item must be a URL string")
        parsed = urlparse(item)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise KodiError("Audio playlist URLs must use HTTP or HTTPS")
        urls.append(item)
    return urls


def wait_for_playback(
    client: KodiClient, expected_label: str, timeout: float = 8.0
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_state: dict[str, Any] = {"active": False, "players": []}
    expected = normalized(expected_label)
    while time.monotonic() < deadline:
        last_state = current(client)
        for player in last_state.get("players", []):
            item = player.get("item") or {}
            actual = normalized(str(item.get("label") or item.get("title") or ""))
            if actual and (expected in actual or actual in expected):
                return last_state
        time.sleep(0.25)
    raise KodiError(f"Kodi did not verify playback of {expected_label!r}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--host", required=True, help=argparse.SUPPRESS)
    result.add_argument("--url", required=True, help=argparse.SUPPRESS)
    result.add_argument("--connect-timeout", type=int, default=10, help=argparse.SUPPRESS)
    commands = result.add_subparsers(dest="command", required=True)

    find_movie = commands.add_parser("find-movie", help="Find one unambiguous movie")
    find_movie.add_argument("title")
    play_movie = commands.add_parser("play-movie", help="Find and play a movie")
    play_movie.add_argument("title")
    play_movie.add_argument("--start-over", action="store_true")

    find_channel = commands.add_parser("find-channel", help="Find one TV channel")
    find_channel.add_argument("name")
    play_channel = commands.add_parser("play-channel", help="Find and tune a TV channel")
    play_channel.add_argument("name")

    commands.add_parser("current", help="Show and verify active playback")
    play_audio_urls = commands.add_parser(
        "play-audio-urls", help="Replace and play Kodi's audio playlist from JSON stdin"
    )
    play_audio_urls.add_argument("label")
    play_audiobookshelf = commands.add_parser(
        "play-audiobookshelf", help="Play an Audiobookshelf item through its Kodi add-on"
    )
    play_audiobookshelf.add_argument("item_id")
    play_audiobookshelf.add_argument("label")
    seek = commands.add_parser("seek-percent", help="Seek active video by percentage")
    seek.add_argument("percentage", type=float)
    commands.add_parser("start-over", help="Seek active video to the beginning")
    return result


def main() -> int:
    args = parser().parse_args()
    client = KodiClient(args.host, args.url, args.connect_timeout)
    try:
        if args.command in {"find-movie", "play-movie"}:
            movie = choose(movies(client), args.title, "title")
            if args.command == "find-movie":
                emit({"match": movie})
            else:
                client.call(
                    "Player.Open",
                    {
                        "item": {"movieid": movie["movieid"]},
                        "options": {"resume": not args.start_over},
                    },
                )
                emit(
                    {
                        "requested": movie,
                        "playback": wait_for_playback(client, str(movie["title"])),
                    }
                )
        elif args.command in {"find-channel", "play-channel"}:
            channel = choose(channels(client), args.name, "label")
            if args.command == "find-channel":
                emit({"match": channel})
            else:
                client.call("Player.Open", {"item": {"channelid": channel["channelid"]}})
                emit(
                    {
                        "requested": channel,
                        "playback": wait_for_playback(client, str(channel["label"])),
                    }
                )
        elif args.command == "current":
            emit(current(client))
        elif args.command == "play-audio-urls":
            urls = read_audio_urls()
            client.call("Playlist.Clear", {"playlistid": 0})
            for url in urls:
                client.call("Playlist.Add", {"playlistid": 0, "item": {"file": url}})
            client.call("Player.Open", {"item": {"playlistid": 0, "position": 0}})
            emit(
                {
                    "requested": {"label": args.label, "tracks": len(urls)},
                    "playback": wait_for_active_player(client, "audio"),
                }
            )
        elif args.command == "play-audiobookshelf":
            if not re.fullmatch(r"[A-Za-z0-9_-]+", args.item_id):
                raise KodiError("Invalid Audiobookshelf item ID")
            plugin_url = (
                "plugin://plugin.audio.audiobookshelf/"
                f"?action=play&item_id={args.item_id}"
            )
            client.call("Player.Open", {"item": {"file": plugin_url}})
            emit(
                {
                    "requested": {"label": args.label, "item_id": args.item_id},
                    "playback": wait_for_active_player(client, "audio", timeout=20.0),
                }
            )
        elif args.command in {"seek-percent", "start-over"}:
            percentage = 0.0 if args.command == "start-over" else args.percentage
            if percentage < 0.0 or percentage > 100.0:
                raise KodiError("Seek percentage must be between 0 and 100")
            player_id = active_video_player(client)
            client.call(
                "Player.Seek", {"playerid": player_id, "value": {"percentage": percentage}}
            )
            emit(current(client))
        return 0
    except (KodiError, subprocess.TimeoutExpired) as error:
        emit({"error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
