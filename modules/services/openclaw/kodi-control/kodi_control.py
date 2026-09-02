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
from urllib.error import URLError
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import Request, urlopen

YOUTUBE_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
YOUTUBE_CHANNEL_ID_RE = re.compile(r"^UC[A-Za-z0-9_-]{22}$")


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


class InvidiousClient:
    def __init__(self, base_url: str, timeout: int) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def get(self, path: str, **params: Any) -> Any:
        url = f"{self.base_url}/api/v1/{path.lstrip('/')}"
        if params:
            url = f"{url}?{urlencode(params)}"
        request = Request(url, headers={"Accept": "application/json"})
        try:
            with urlopen(request, timeout=self.timeout) as response:
                return json.load(response)
        except URLError as error:
            raise KodiError(f"Invidious request failed: {error}") from error
        except json.JSONDecodeError as error:
            raise KodiError("Invidious returned invalid JSON") from error


def require_invidious(args: argparse.Namespace) -> InvidiousClient:
    if not args.invidious_url:
        raise KodiError("Invidious is not configured for this Kodi target")
    return InvidiousClient(args.invidious_url, args.connect_timeout)


def parse_youtube_video_id(value: str) -> str:
    value = value.strip()
    if YOUTUBE_VIDEO_ID_RE.fullmatch(value):
        return value

    parsed = urlparse(value)
    host = parsed.netloc.lower()
    if host.endswith("youtu.be"):
        candidate = parsed.path.strip("/")
        if YOUTUBE_VIDEO_ID_RE.fullmatch(candidate):
            return candidate
    else:
        query = parse_qs(parsed.query)
        candidate = query.get("v", [""])[0]
        if YOUTUBE_VIDEO_ID_RE.fullmatch(candidate):
            return candidate
        match = re.search(r"/(?:shorts|embed|live)/([A-Za-z0-9_-]{11})", parsed.path)
        if match:
            return match.group(1)

    raise KodiError(f"Could not parse a YouTube video ID from {value!r}")


def find_youtube_channel(invidious: InvidiousClient, query: str) -> dict[str, Any]:
    if YOUTUBE_CHANNEL_ID_RE.fullmatch(query):
        return {"id": query, "author": query}

    results = invidious.get("search", q=query, type="channel")
    if not isinstance(results, list):
        raise KodiError("Invidious channel search failed")
    channels = [
        {
            "id": item.get("authorId"),
            "author": item.get("author"),
            "sub_count": item.get("subCount"),
        }
        for item in results
        if item.get("type") == "channel" and item.get("authorId")
    ]
    if not channels:
        raise KodiError(f"No YouTube channel found for {query!r}")
    return choose(channels, query, "author")


def latest_youtube_channel_video(invidious: InvidiousClient, channel_id: str) -> dict[str, Any]:
    result = invidious.get(f"channels/{channel_id}/videos")
    videos = result.get("videos") if isinstance(result, dict) else result
    if not isinstance(videos, list) or not videos:
        raise KodiError("This YouTube channel has no videos")
    video_id = videos[0].get("videoId")
    if not video_id:
        raise KodiError("Invidious did not return a playable video ID")
    return videos[0]


def movies(client: KodiClient) -> list[dict[str, Any]]:
    result = client.call(
        "VideoLibrary.GetMovies",
        {"properties": ["title", "year", "resume"], "sort": {"method": "title"}},
    )
    return result.get("movies", []) if isinstance(result, dict) else []


def episodes(client: KodiClient) -> list[dict[str, Any]]:
    result = client.call(
        "VideoLibrary.GetEpisodes",
        {
            "properties": ["title", "showtitle", "season", "episode", "resume"],
            "sort": {"method": "title"},
        },
    )
    return result.get("episodes", []) if isinstance(result, dict) else []


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


def seconds(value: Any) -> float | None:
    if not isinstance(value, dict):
        return None
    try:
        return round(
            int(value.get("hours", 0)) * 3600
            + int(value.get("minutes", 0)) * 60
            + int(value.get("seconds", 0))
            + int(value.get("milliseconds", 0)) / 1000,
            3,
        )
    except (TypeError, ValueError):
        return None


def source_name(item: dict[str, Any]) -> str | None:
    path = str(item.get("file") or "")
    if path.startswith("plugin://plugin.audio.audiobookshelf/"):
        return "audiobookshelf"
    if path.startswith("plugin://plugin.kodi.navidrome/"):
        return "navidrome"
    if path.startswith("plugin://plugin.video.invidious/"):
        return "invidious"
    if path.startswith("pvr://") or item.get("type") == "channel":
        return "pvr"
    if path:
        return "kodi"
    return None


def normalize_player(
    client: KodiClient, player: dict[str, Any]
) -> dict[str, Any]:
    player_id = int(player["playerid"])
    item_result = client.call(
        "Player.GetItem",
        {
            "playerid": player_id,
            "properties": [
                "title", "showtitle", "season", "episode", "artist", "album",
                "file", "year",
            ],
        },
    )
    properties = client.call(
        "Player.GetProperties",
        {
            "playerid": player_id,
            "properties": ["percentage", "time", "totaltime", "speed"],
        },
    )
    item = item_result.get("item", {}) if isinstance(item_result, dict) else {}
    properties = properties if isinstance(properties, dict) else {}
    speed = properties.get("speed", 0)
    state = "paused" if speed == 0 else "playing"
    return {
        "state": state,
        "item": {
            "id": item.get("id"),
            "title": item.get("title") or item.get("label"),
            "label": item.get("label") or item.get("title"),
            "show": item.get("showtitle"),
            "season": item.get("season"),
            "episode": item.get("episode"),
            "artist": item.get("artist"),
            "album": item.get("album"),
            "year": item.get("year"),
        },
        "position": seconds(properties.get("time")),
        "duration": seconds(properties.get("totaltime")),
        "percentage": properties.get("percentage"),
        "media_type": item.get("type") or player.get("type"),
        "playback_kind": player.get("type"),
        "source": source_name(item),
        "playback_target": client.host + "-kodi",
    }


def current(client: KodiClient) -> dict[str, Any]:
    players = client.call("Player.GetActivePlayers") or []
    if not players:
        return {
            "available": True,
            "state": "stopped",
            "item": None,
            "position": None,
            "duration": None,
            "percentage": None,
            "media_type": None,
            "playback_kind": None,
            "source": None,
            "playback_target": client.host + "-kodi",
        }
    return {"available": True, **normalize_player(client, players[0])}


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
        if last_state.get("playback_kind") == player_type and last_state.get("state") == "playing":
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


def read_play_request() -> dict[str, Any]:
    try:
        value = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        raise KodiError("Playback request must be a JSON object") from error
    if not isinstance(value, dict):
        raise KodiError("Playback request must be a JSON object")
    return value


def wait_for_playback(
    client: KodiClient, expected_label: str, timeout: float = 8.0
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_state: dict[str, Any] = {"active": False, "players": []}
    expected = normalized(expected_label)
    while time.monotonic() < deadline:
        last_state = current(client)
        item = last_state.get("item") or {}
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
    result.add_argument("--invidious-url", default=None, help=argparse.SUPPRESS)
    commands = result.add_subparsers(dest="command", required=True)

    find_movie = commands.add_parser("find-movie", help="Find one unambiguous movie")
    find_movie.add_argument("title")
    play_movie = commands.add_parser("play-movie", help="Find and play a movie")
    play_movie.add_argument("title")
    play_movie.add_argument("--start-over", action="store_true")
    play_episode = commands.add_parser("play-episode", help="Find and play one TV episode")
    play_episode.add_argument("show")
    play_episode.add_argument("season", type=int)
    play_episode.add_argument("episode", type=int)

    find_channel = commands.add_parser("find-channel", help="Find one TV channel")
    find_channel.add_argument("name")
    play_channel = commands.add_parser("play-channel", help="Find and tune a TV channel")
    play_channel.add_argument("name")

    find_youtube_channel = commands.add_parser(
        "find-youtube-channel", help="Find one unambiguous YouTube channel"
    )
    find_youtube_channel.add_argument("query")
    play_youtube_video = commands.add_parser(
        "play-youtube-video", help="Play a specific YouTube video by ID or URL"
    )
    play_youtube_video.add_argument("video")
    play_youtube_channel_latest = commands.add_parser(
        "play-youtube-channel-latest",
        help="Play the most recent video from a YouTube channel",
    )
    play_youtube_channel_latest.add_argument("query")

    commands.add_parser("status", aliases=["current"], help="Show normalized playback state")
    commands.add_parser("play", help="Play a normalized media request from JSON stdin")
    for action in ("pause", "resume", "stop"):
        commands.add_parser(action, help=f"{action.title()} active playback")
    raw = commands.add_parser("raw", help="Call Kodi JSON-RPC directly (debug use)")
    raw.add_argument("method")
    raw.add_argument("params", nargs="?", default="{}", help="JSON object")
    play_audio_urls = commands.add_parser(
        "play-audio-urls", help="Replace and play Kodi's audio playlist from JSON stdin"
    )
    play_audio_urls.add_argument("label")
    play_audiobookshelf = commands.add_parser(
        "play-audiobookshelf", help="Play an Audiobookshelf item through its Kodi add-on"
    )
    play_audiobookshelf.add_argument("item_id")
    play_audiobookshelf.add_argument("label")
    play_navidrome = commands.add_parser(
        "play-navidrome", help="Play a Navidrome song through its Kodi add-on"
    )
    play_navidrome.add_argument("song_id")
    play_navidrome.add_argument("label")
    play_navidrome.add_argument("artist")
    seek = commands.add_parser("seek-percent", help="Seek active video by percentage")
    seek.add_argument("percentage", type=float)
    commands.add_parser("start-over", help="Seek active video to the beginning")
    return result


def main() -> int:
    args = parser().parse_args()
    client = KodiClient(args.host, args.url, args.connect_timeout)
    try:
        if args.command == "play":
            request = read_play_request()
            source = request.get("source")
            media_type = request.get("media_type")
            if source == "jellyfin" and media_type == "movie":
                movie = choose(movies(client), str(request.get("title", "")), "title")
                client.call("Player.Open", {"item": {"movieid": movie["movieid"]}, "options": {"resume": True}})
                emit({"requested": request, "playback": wait_for_playback(client, str(movie["title"]))})
            elif source == "jellyfin" and media_type == "episode":
                matches = [
                    item for item in episodes(client)
                    if normalized(str(item.get("showtitle", ""))) == normalized(str(request.get("show", "")))
                    and item.get("season") == request.get("season")
                    and item.get("episode") == request.get("episode")
                ]
                if len(matches) != 1:
                    raise KodiError(f"Expected one matching Kodi episode; found {len(matches)}")
                item = matches[0]
                client.call("Player.Open", {"item": {"episodeid": item["episodeid"]}, "options": {"resume": True}})
                emit({"requested": request, "playback": wait_for_playback(client, str(item["title"]))})
            elif source == "navidrome" and media_type == "song":
                plugin_url = "plugin://plugin.kodi.navidrome/?" + urlencode({"action": "play_track", "id": request.get("id", ""), "title": request.get("title", ""), "artist": request.get("artist", "")})
                client.call("Player.Open", {"item": {"file": plugin_url}})
                emit({"requested": request, "playback": wait_for_active_player(client, "audio", timeout=20.0)})
            elif source == "audiobookshelf" and media_type in {"book", "podcast"}:
                item_id = str(request.get("id", ""))
                if not re.fullmatch(r"[A-Za-z0-9_-]+", item_id):
                    raise KodiError("Invalid Audiobookshelf item ID")
                plugin_url = f"plugin://plugin.audio.audiobookshelf/?action=play&item_id={item_id}&auto_resume=1"
                client.call("Player.Open", {"item": {"file": plugin_url}})
                emit({"requested": request, "playback": wait_for_active_player(client, "audio", timeout=20.0)})
            else:
                raise KodiError(f"Unsupported playback request: source={source!r}, media_type={media_type!r}")
        elif args.command in {"find-movie", "play-movie"}:
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
        elif args.command == "play-episode":
            matches = [
                item for item in episodes(client)
                if normalized(str(item.get("showtitle", ""))) == normalized(args.show)
                and item.get("season") == args.season
                and item.get("episode") == args.episode
            ]
            if len(matches) != 1:
                raise KodiError(
                    f"Expected one Kodi episode for {args.show} S{args.season:02d}E{args.episode:02d}; found {len(matches)}"
                )
            episode = matches[0]
            client.call(
                "Player.Open",
                {"item": {"episodeid": episode["episodeid"]}, "options": {"resume": True}},
            )
            emit({"requested": episode, "playback": wait_for_playback(client, str(episode["title"]))})
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
        elif args.command == "find-youtube-channel":
            invidious = require_invidious(args)
            emit({"match": find_youtube_channel(invidious, args.query)})
        elif args.command == "play-youtube-video":
            video_id = parse_youtube_video_id(args.video)
            plugin_url = "plugin://plugin.video.invidious/?" + urlencode(
                {"action": "play_video", "video_id": video_id}
            )
            client.call("Player.Open", {"item": {"file": plugin_url}})
            emit(
                {
                    "requested": {"video_id": video_id},
                    "playback": wait_for_active_player(client, "video", timeout=20.0),
                }
            )
        elif args.command == "play-youtube-channel-latest":
            invidious = require_invidious(args)
            channel = find_youtube_channel(invidious, args.query)
            video = latest_youtube_channel_video(invidious, channel["id"])
            plugin_url = "plugin://plugin.video.invidious/?" + urlencode(
                {"action": "play_video", "video_id": video["videoId"]}
            )
            client.call("Player.Open", {"item": {"file": plugin_url}})
            emit(
                {
                    "requested": {
                        "channel": channel,
                        "video_id": video["videoId"],
                        "title": video.get("title"),
                    },
                    "playback": wait_for_active_player(client, "video", timeout=20.0),
                }
            )
        elif args.command in {"status", "current"}:
            emit(current(client))
        elif args.command in {"pause", "resume", "stop"}:
            players = client.call("Player.GetActivePlayers") or []
            if not players:
                if args.command == "stop":
                    emit(current(client))
                    return 0
                raise KodiError("Kodi has no active player")
            player_id = int(players[0]["playerid"])
            if args.command == "stop":
                client.call("Player.Stop", {"playerid": player_id})
            else:
                client.call(
                    "Player.PlayPause",
                    {"playerid": player_id, "play": args.command == "resume"},
                )
            emit(current(client))
        elif args.command == "raw":
            try:
                params = json.loads(args.params)
            except json.JSONDecodeError as error:
                raise KodiError("Raw params must be a JSON object") from error
            if not isinstance(params, dict):
                raise KodiError("Raw params must be a JSON object")
            emit({"result": client.call(args.method, params)})
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
                f"?action=play&item_id={args.item_id}&auto_resume=1"
            )
            client.call("Player.Open", {"item": {"file": plugin_url}})
            emit(
                {
                    "requested": {"label": args.label, "item_id": args.item_id},
                    "playback": wait_for_active_player(client, "audio", timeout=20.0),
                }
            )
        elif args.command == "play-navidrome":
            if not args.song_id or len(args.song_id) > 512:
                raise KodiError("Invalid Navidrome song ID")
            plugin_url = "plugin://plugin.kodi.navidrome/?" + urlencode(
                {
                    "action": "play_track",
                    "id": args.song_id,
                    "title": args.label,
                    "artist": args.artist,
                }
            )
            client.call("Player.Open", {"item": {"file": plugin_url}})
            emit(
                {
                    "requested": {
                        "label": args.label,
                        "artist": args.artist,
                        "song_id": args.song_id,
                    },
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
        message = str(error)
        unavailable = "transport failed" in message.casefold() or isinstance(error, subprocess.TimeoutExpired)
        emit({"available": False if unavailable else True, "error": {"code": "unavailable" if unavailable else "operation_failed", "message": message}})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
