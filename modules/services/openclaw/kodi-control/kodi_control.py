#!/usr/bin/env python3
"""Focused media-service playback through Kodi on alan-tv."""

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


def choose(items: list[dict[str, Any]], query: str, label_key: str) -> dict[str, Any]:
    query_key = normalized(query)
    if not query_key:
        raise KodiError("A non-empty search value is required")

    exact = [item for item in items if normalized(str(item.get(label_key, ""))) == query_key]
    # Invidious can return several uploads with the same title/channel name.
    # Its search results are relevance ordered, so the first exact match is the
    # most useful deterministic choice for a title-only voice request.
    if exact:
        return exact[0]

    contained = [
        item for item in items
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
            if len(ranked) > 1 else 0.0
        )
        if best_score >= 0.72 and best_score - second_score >= 0.08:
            return ranked[0]

    candidates = [str(item.get(label_key, "")) for item in ranked[:5]]
    if candidates:
        raise KodiError("No unambiguous match. Candidates: " + ", ".join(candidates))
    raise KodiError("No matching items were found")


class KodiClient:
    def __init__(self, host: str, url: str, connect_timeout: int) -> None:
        self.host = host
        self.url = url
        self.connect_timeout = connect_timeout
        self.request_id = 0

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        self.request_id += 1
        payload: dict[str, Any] = {
            "jsonrpc": "2.0", "id": self.request_id, "method": method,
        }
        if params is not None:
            payload["params"] = params

        command = [
            "ssh", "-o", "BatchMode=yes", "-o",
            f"ConnectTimeout={self.connect_timeout}", self.host,
            (
                f"curl -sS --max-time 15 -X POST {self.url} "
                "-H 'Content-Type: application/json' --data-binary @-"
            ),
        ]
        completed = subprocess.run(
            command, input=json.dumps(payload, separators=(",", ":")), text=True,
            capture_output=True, timeout=self.connect_timeout + 20, check=False,
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


class InvidiousClient:
    def __init__(self, base_url: str, timeout: int) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def get(self, path: str, **params: Any) -> Any:
        url = f"{self.base_url}/api/v1/{path.lstrip('/')}"
        if params:
            url = f"{url}?{urlencode(params)}"
        try:
            request = Request(url, headers={"Accept": "application/json"})
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


def movies(client: KodiClient) -> list[dict[str, Any]]:
    result = client.call(
        "VideoLibrary.GetMovies",
        {"properties": ["title", "year"], "sort": {"method": "title"}},
    )
    return result.get("movies", []) if isinstance(result, dict) else []


def episodes(client: KodiClient) -> list[dict[str, Any]]:
    result = client.call(
        "VideoLibrary.GetEpisodes",
        {
            "properties": ["title", "showtitle", "season", "episode"],
            "sort": {"method": "title"},
        },
    )
    return result.get("episodes", []) if isinstance(result, dict) else []


def current_item(client: KodiClient) -> dict[str, Any] | None:
    players = client.call("Player.GetActivePlayers") or []
    if not players:
        return None
    player_id = int(players[0]["playerid"])
    result = client.call(
        "Player.GetItem",
        {"playerid": player_id, "properties": ["title", "showtitle", "season", "episode", "file"]},
    )
    return result.get("item") if isinstance(result, dict) else None


def wait_for_playback(client: KodiClient, expected_label: str, timeout: float = 20.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    expected = normalized(expected_label)
    while time.monotonic() < deadline:
        item = current_item(client)
        if item:
            actual = normalized(str(item.get("label") or item.get("title") or ""))
            if not expected or expected in actual or actual in expected:
                return item
        time.sleep(0.25)
    raise KodiError(f"Kodi did not verify playback of {expected_label!r}")


def parse_youtube_video_id(value: str) -> str | None:
    value = value.strip()
    if YOUTUBE_VIDEO_ID_RE.fullmatch(value):
        return value
    parsed = urlparse(value)
    if parsed.netloc.lower().endswith("youtu.be"):
        candidate = parsed.path.strip("/")
        return candidate if YOUTUBE_VIDEO_ID_RE.fullmatch(candidate) else None
    query_id = parse_qs(parsed.query).get("v", [""])[0]
    if YOUTUBE_VIDEO_ID_RE.fullmatch(query_id):
        return query_id
    match = re.search(r"/(?:shorts|embed|live)/([A-Za-z0-9_-]{11})", parsed.path)
    return match.group(1) if match else None


def find_youtube_video(invidious: InvidiousClient, query: str) -> dict[str, Any]:
    video_id = parse_youtube_video_id(query)
    if video_id:
        return {"videoId": video_id, "title": query}
    results = invidious.get("search", q=query, type="video")
    videos = [
        {"videoId": item.get("videoId"), "title": item.get("title"), "author": item.get("author")}
        for item in results if item.get("type") == "video" and item.get("videoId")
    ] if isinstance(results, list) else []
    return choose(videos, query, "title")


def find_youtube_channel(invidious: InvidiousClient, query: str) -> dict[str, Any]:
    if YOUTUBE_CHANNEL_ID_RE.fullmatch(query):
        return {"id": query, "author": query}
    results = invidious.get("search", q=query, type="channel")
    channels = [
        {"id": item.get("authorId"), "author": item.get("author")}
        for item in results if item.get("type") == "channel" and item.get("authorId")
    ] if isinstance(results, list) else []
    return choose(channels, query, "author")


def play_invidious_video(client: KodiClient, video: dict[str, Any]) -> None:
    plugin_url = "plugin://plugin.video.invidious/?" + urlencode(
        {"action": "play_video", "video_id": video["videoId"]}
    )
    client.call("Player.Open", {"item": {"file": plugin_url}})


def navidrome_url(track: dict[str, Any]) -> str:
    track_id = str(track.get("id", ""))
    if not track_id or len(track_id) > 512:
        raise KodiError("Invalid Navidrome song ID")
    return "plugin://plugin.kodi.navidrome/?" + urlencode(
        {
            "action": "play_track",
            "id": track_id,
            "title": str(track.get("title", "")),
            "artist": str(track.get("artist", "")),
        }
    )


def read_navidrome_tracks() -> list[dict[str, Any]]:
    try:
        tracks = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        raise KodiError("Navidrome album input must be a JSON array") from error
    if not isinstance(tracks, list) or not tracks:
        raise KodiError("Navidrome album has no playable songs")
    if len(tracks) > 1000:
        raise KodiError("Navidrome albums are limited to 1000 songs")
    if not all(isinstance(track, dict) for track in tracks):
        raise KodiError("Every Navidrome album item must be an object")
    return tracks


def wait_for_audio(client: KodiClient, timeout: float = 20.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        players = client.call("Player.GetActivePlayers") or []
        if any(player.get("type") == "audio" for player in players):
            item = current_item(client)
            return item or {"type": "audio"}
        time.sleep(0.25)
    raise KodiError("Kodi did not start an active audio player")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--host", required=True, help=argparse.SUPPRESS)
    result.add_argument("--url", required=True, help=argparse.SUPPRESS)
    result.add_argument("--connect-timeout", type=int, default=10, help=argparse.SUPPRESS)
    result.add_argument("--invidious-url", default=None, help=argparse.SUPPRESS)
    commands = result.add_subparsers(dest="command", required=True)

    movie = commands.add_parser("play-jellyfin-movie", help="Play a Jellyfin movie synced into Kodi")
    movie.add_argument("title")
    movie.add_argument("year", type=int)
    episode = commands.add_parser("play-jellyfin-episode", help="Play a Jellyfin episode synced into Kodi")
    episode.add_argument("show")
    episode.add_argument("season", type=int)
    episode.add_argument("episode", type=int)
    song = commands.add_parser("play-navidrome-song", help="Play one Navidrome song through its Kodi add-on")
    song.add_argument("song_id")
    song.add_argument("title")
    song.add_argument("artist")
    album = commands.add_parser("play-navidrome-album", help="Play a Navidrome album through its Kodi add-on")
    album.add_argument("title")
    audiobook = commands.add_parser("play-audiobookshelf", help="Resume an Audiobookshelf book through its Kodi add-on")
    audiobook.add_argument("item_id")
    audiobook.add_argument("title")
    video = commands.add_parser("play-youtube-video", help="Play a YouTube video by title, ID, or URL")
    video.add_argument("query")
    latest = commands.add_parser("play-youtube-channel-latest", help="Play the latest video from a YouTube channel")
    latest.add_argument("channel")
    return result


def main() -> int:
    args = parser().parse_args()
    client = KodiClient(args.host, args.url, args.connect_timeout)
    try:
        if args.command == "play-jellyfin-movie":
            matches = [
                item for item in movies(client)
                if normalized(str(item.get("title", ""))) == normalized(args.title)
                and item.get("year") == args.year
            ]
            if len(matches) != 1:
                raise KodiError(
                    f"Expected one Kodi movie for {args.title} ({args.year}); "
                    f"found {len(matches)}"
                )
            movie = matches[0]
            client.call("Player.Open", {"item": {"movieid": movie["movieid"]}, "options": {"resume": True}})
            emit({"requested": movie, "playing": wait_for_playback(client, str(movie["title"]))})
        elif args.command == "play-jellyfin-episode":
            matches = [
                item for item in episodes(client)
                if normalized(str(item.get("showtitle", ""))) == normalized(args.show)
                and item.get("season") == args.season
                and item.get("episode") == args.episode
            ]
            if len(matches) != 1:
                raise KodiError(
                    f"Expected one Kodi episode for {args.show} "
                    f"S{args.season:02d}E{args.episode:02d}; found {len(matches)}"
                )
            episode = matches[0]
            client.call("Player.Open", {"item": {"episodeid": episode["episodeid"]}, "options": {"resume": True}})
            emit({"requested": episode, "playing": wait_for_playback(client, str(episode["title"]))})
        elif args.command == "play-navidrome-song":
            track = {"id": args.song_id, "title": args.title, "artist": args.artist}
            client.call("Player.Open", {"item": {"file": navidrome_url(track)}})
            emit({"requested": track, "playing": wait_for_audio(client)})
        elif args.command == "play-navidrome-album":
            tracks = read_navidrome_tracks()
            client.call("Playlist.Clear", {"playlistid": 0})
            for track in tracks:
                client.call(
                    "Playlist.Add",
                    {"playlistid": 0, "item": {"file": navidrome_url(track)}},
                )
            client.call("Player.Open", {"item": {"playlistid": 0, "position": 0}})
            emit(
                {
                    "requested": {"title": args.title, "songs": len(tracks)},
                    "playing": wait_for_audio(client),
                }
            )
        elif args.command == "play-audiobookshelf":
            if not re.fullmatch(r"[A-Za-z0-9_-]+", args.item_id):
                raise KodiError("Invalid Audiobookshelf item ID")
            plugin_url = "plugin://plugin.audio.audiobookshelf/?" + urlencode(
                {"action": "play", "item_id": args.item_id, "auto_resume": "1"}
            )
            client.call("Player.Open", {"item": {"file": plugin_url}})
            emit(
                {
                    "requested": {"id": args.item_id, "title": args.title},
                    "playing": wait_for_audio(client),
                }
            )
        elif args.command == "play-youtube-video":
            video = find_youtube_video(require_invidious(args), args.query)
            play_invidious_video(client, video)
            emit({"requested": video, "playing": wait_for_playback(client, "")})
        elif args.command == "play-youtube-channel-latest":
            invidious = require_invidious(args)
            channel = find_youtube_channel(invidious, args.channel)
            response = invidious.get(f"channels/{channel['id']}/videos")
            videos = response.get("videos") if isinstance(response, dict) else response
            if not isinstance(videos, list) or not videos or not videos[0].get("videoId"):
                raise KodiError("This YouTube channel has no playable videos")
            video = videos[0]
            play_invidious_video(client, video)
            emit({"requested": {"channel": channel, "video": video}, "playing": wait_for_playback(client, "")})
        return 0
    except (KodiError, subprocess.TimeoutExpired) as error:
        emit({"error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
