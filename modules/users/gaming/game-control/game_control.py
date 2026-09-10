#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlencode


PLATFORMS = {
    "gamecube": {"extensions": {".iso", ".gcm", ".rvz", ".wbfs"}, "launcher": "Dolphin"},
    "wii": {"extensions": {".iso", ".rvz", ".wbfs"}, "launcher": "Dolphin"},
    "n64": {"extensions": {".z64", ".n64", ".v64"}, "launcher": "RetroArch"},
    "nds": {"extensions": {".nds"}, "launcher": "melonDS"},
    "3ds": {"extensions": {".3ds", ".cci", ".cxi"}, "launcher": "Azahar"},
    "switch": {"extensions": {".xci", ".nsp"}, "launcher": "Ryubing"},
}

APP_IDS = {
    "Dolphin": ["dolphin-emu"],
    "RetroArch": ["com.libretro.RetroArch", "retroarch"],
    "melonDS": ["net.kuribo64.melonDS", "melonDS"],
    "Azahar": ["org.azahar_emu.Azahar", "azahar"],
    "Ryubing": ["Ryujinx"],
}

PROCESS_NAMES = {
    "Dolphin": ["dolphin-emu"],
    "RetroArch": ["retroarch"],
    "melonDS": ["melonDS"],
    "Azahar": ["azahar"],
    "Ryubing": ["Ryujinx", "ryubing"],
}


def fail(message, code=1):
    print(json.dumps({"ok": False, "error": message}, separators=(",", ":")))
    raise SystemExit(code)


def normalized(value):
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def readable_stem(path):
    value = path.stem
    value = re.sub(r"\[[^]]*\]", " ", value)
    value = re.sub(r"\([^)]*(?:USA|Europe|Japan|World|Rev|En)[^)]*\)", " ", value, flags=re.I)
    value = re.sub(r"\b\d+\.\d+(?:\.\d+)*\b", " ", value)
    value = re.sub(r"\b(?:v\d+|trim)\b", " ", value, flags=re.I)
    value = value.replace("_", " ").replace(".", " ")
    value = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", value)
    value = re.sub(r"\s+", " ", value).strip(" -_")
    return value


def dolphin_title(path):
    tool = shutil.which("dolphin-tool")
    if not tool:
        return None
    try:
        result = subprocess.run(
            [tool, "header", "-i", str(path)], capture_output=True, text=True,
            timeout=5, check=False,
        )
    except subprocess.TimeoutExpired:
        return None
    match = re.search(r"^Internal Name:\s*(.+)$", result.stdout, re.M)
    if not match:
        return None
    value = match.group(1).strip()
    value = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", value)
    return value


def parse_steam_manifest(path):
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return None
    appid = re.search(r'"appid"\s+"([0-9]+)"', text, re.I)
    name = re.search(r'"name"\s+"([^"]+)"', text, re.I)
    if not appid or not name:
        return None
    title = name.group(1).strip()
    if re.search(r"(Proton|Steam Linux Runtime|Steamworks Common Redistributables)", title, re.I):
        return None
    return {
        "id": f"steam:{appid.group(1)}",
        "title": title,
        "platform": "steam",
        "launcher": "Steam",
        "appid": appid.group(1),
    }


def nested_string(value, *paths):
    for path in paths:
        current = value
        for key in path:
            if not isinstance(current, dict):
                current = None
                break
            current = current.get(key)
        if isinstance(current, str) and current.strip():
            return current.strip()
    return None


def heroic_installed_games():
    games = []
    cache_root = Path.home() / ".config/heroic/store_cache"
    sources = {
        "legendary": cache_root / "legendary_install_info.json",
        "gog": cache_root / "gog_install_info.json",
        "nile": cache_root / "nile_install_info.json",
    }
    for runner, path in sources.items():
        try:
            contents = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(contents, dict):
            records = [
                (key, value) for key, value in contents.items()
                if not key.startswith("__") and isinstance(value, dict)
            ]
        elif isinstance(contents, list):
            records = [(str(index), value) for index, value in enumerate(contents) if isinstance(value, dict)]
        else:
            continue
        for key, record in records:
            app_name = nested_string(
                record,
                ("game", "app_name"),
                ("game", "appName"),
                ("app_name",),
                ("appName",),
                ("id",),
            ) or key
            title = nested_string(
                record,
                ("game", "title"),
                ("game", "app_title"),
                ("title",),
                ("app_title",),
                ("name",),
            )
            if not title or not app_name:
                continue
            token = hashlib.sha256(f"{runner}:{app_name}".encode()).hexdigest()[:16]
            games.append({
                "id": f"heroic:{runner}:{token}",
                "title": title,
                "platform": "heroic",
                "launcher": "Heroic",
                "_heroic_app_name": app_name,
                "_heroic_runner": runner,
            })
    return games


def inventory(args):
    games = []
    title_overrides = json.loads(args.title_overrides_json)
    root = Path(args.rom_root).resolve()
    if root.is_dir():
        for platform, spec in PLATFORMS.items():
            directory = root / platform
            if not directory.is_dir():
                continue
            for path in sorted(directory.rglob("*")):
                if not path.is_file() or path.suffix.casefold() not in spec["extensions"]:
                    continue
                relative = path.relative_to(root).as_posix()
                title = title_overrides.get(relative)
                if not title and platform in {"gamecube", "wii"}:
                    title = dolphin_title(path)
                title = title or readable_stem(path)
                token = hashlib.sha256(relative.encode()).hexdigest()[:16]
                games.append({
                    "id": f"rom:{platform}:{token}",
                    "title": title,
                    "platform": platform,
                    "launcher": spec["launcher"],
                    "_path": str(path),
                })

    steam_roots = [
        Path.home() / ".local/share/Steam/steamapps",
        Path.home() / ".steam/steam/steamapps",
    ]
    for initial_root in list(steam_roots):
        library_file = initial_root / "libraryfolders.vdf"
        try:
            library_text = library_file.read_text(errors="replace")
        except OSError:
            continue
        for match in re.finditer(r'"path"\s+"([^"]+)"', library_text, re.I):
            library_root = Path(match.group(1).replace("\\\\", "\\")) / "steamapps"
            if library_root not in steam_roots:
                steam_roots.append(library_root)
    seen_manifests = set()
    for steam_root in steam_roots:
        for manifest in sorted(steam_root.glob("appmanifest_*.acf")):
            try:
                key = manifest.resolve()
            except OSError:
                continue
            if key in seen_manifests:
                continue
            seen_manifests.add(key)
            game = parse_steam_manifest(manifest)
            if game:
                games.append(game)

    games.extend(heroic_installed_games())

    # Prefer compressed Dolphin images when the same title exists twice.
    deduped = {}
    for game in games:
        key = (
            game["platform"],
            game.get("_heroic_runner", ""),
            normalized(game["title"]),
        )
        previous = deduped.get(key)
        if previous and previous.get("_path", "").endswith(".rvz"):
            continue
        deduped[key] = game
    return sorted(deduped.values(), key=lambda game: (game["title"].casefold(), game["platform"]))


def public(game):
    return {key: game[key] for key in ("id", "title", "platform", "launcher")}


def find_id(games, game_id):
    return next((game for game in games if game["id"] == game_id), None)


def state_path():
    return Path.home() / ".local/state/alanix-game-control/running.json"


def load_state():
    try:
        value = json.loads(state_path().read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(value):
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")))
    os.replace(temporary, path)


def search(games, query):
    wanted = normalized(query)
    exact = [game for game in games if normalized(game["title"]) == wanted]
    if exact:
        return exact
    return [game for game in games if wanted in normalized(game["title"])]


def sway_tree():
    result = subprocess.run(["swaymsg", "-r", "-t", "get_tree"], capture_output=True, text=True)
    if result.returncode != 0:
        fail("No controllable Sway session is available", 69)
    return json.loads(result.stdout)


def walk(node):
    yield node
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        yield from walk(child)


def open_app_ids():
    values = set()
    for node in walk(sway_tree()):
        app_id = node.get("app_id") or (node.get("window_properties") or {}).get("class")
        if app_id:
            values.add(app_id.casefold())
    return values


def open_windows():
    return [
        {
            "id": node.get("id"),
            "app_id": node.get("app_id") or (node.get("window_properties") or {}).get("class"),
            "pid": node.get("pid"),
        }
        for node in walk(sway_tree())
        if node.get("id") and (
            node.get("app_id") or (node.get("window_properties") or {}).get("class")
        )
    ]


def expected_ids(game):
    if game["platform"] == "steam":
        return [f"steam_app_{game['appid']}"]
    return APP_IDS[game["launcher"]]


def heroic_process_ids(game):
    expected = {
        b"HEROIC_APP_NAME": os.fsencode(game["_heroic_app_name"]),
        b"HEROIC_APP_RUNNER": os.fsencode(game["_heroic_runner"]),
    }
    matches = set()
    for process_dir in Path("/proc").glob("[0-9]*"):
        try:
            entries = (process_dir / "environ").read_bytes().split(b"\0")
        except OSError:
            continue
        environment = dict(entry.split(b"=", 1) for entry in entries if b"=" in entry)
        if all(environment.get(key) == value for key, value in expected.items()):
            matches.add(int(process_dir.name))
    return matches


def heroic_is_running(game):
    return bool(heroic_process_ids(game))


def process_running(names):
    expected = set(names)
    for process_dir in Path("/proc").glob("[0-9]*"):
        try:
            process_name = (process_dir / "comm").read_text().strip()
            argv = (process_dir / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        executable = os.path.basename(os.fsdecode(argv[0])) if argv and argv[0] else ""
        if process_name in expected or executable in expected:
            return True
    return False


def command_line_contains(value):
    needle = os.fsencode(value)
    for process_dir in Path("/proc").glob("[0-9]*"):
        try:
            arguments = (process_dir / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if needle in arguments:
            return True
    return False


def launcher_is_running(game, ids=None):
    if game["platform"] in {"steam", "heroic"}:
        return is_running(game, ids)
    ids = open_app_ids() if ids is None else ids
    if any(value.casefold() in ids for value in expected_ids(game)):
        return True
    return process_running(PROCESS_NAMES[game["launcher"]])


def is_running(game, ids=None):
    if game["platform"] == "heroic":
        return heroic_is_running(game)
    if game["platform"] != "steam":
        return command_line_contains(game["_path"]) and launcher_is_running(game, ids)
    ids = open_app_ids() if ids is None else ids
    return any(value.casefold() in ids for value in expected_ids(game))


def command_for(game, args):
    if game["platform"] == "steam":
        return ["steam", "-gamepadui", f"steam://rungameid/{game['appid']}"]
    if game["platform"] == "heroic":
        query = urlencode({
            "appName": game["_heroic_app_name"],
            "runner": game["_heroic_runner"],
        })
        return [
            "heroic",
            "--no-gui",
            "--force-device-scale-factor=1",
            f"heroic://launch?{query}",
        ]
    path = game["_path"]
    platform = game["platform"]
    if platform in {"gamecube", "wii"}:
        return ["dolphin-emu", "-b", "-e", path]
    if platform == "n64":
        return ["retroarch", "-L", args.retroarch_core, path]
    if platform == "nds":
        return ["melonDS", "-f", path]
    if platform == "3ds":
        return ["azahar", "-f", path]
    if platform == "switch":
        return ["ryujinx", path]
    fail("Unsupported game platform", 64)


def launch(game, args):
    state = load_state()
    if is_running(game):
        if game["platform"] not in {"steam", "heroic"}:
            state[game["launcher"]] = game["id"]
            save_state(state)
        print(json.dumps({"ok": True, "alreadyRunning": True, "game": public(game)}, separators=(",", ":")))
        return
    if game["platform"] not in {"steam", "heroic"} and launcher_is_running(game):
        fail(f"{game['launcher']} is already running without the selected game; close it before launching this title", 69)
    if game["platform"] == "heroic":
        active_game = next(
            (
                candidate for candidate in inventory(args)
                if candidate["platform"] == "heroic"
                and candidate["id"] != game["id"]
                and heroic_is_running(candidate)
            ),
            None,
        )
        if active_game:
            fail("Another Heroic game is already running; close it before launching this title", 69)

    command = command_for(game, args)
    missing = shutil.which(command[0]) is None
    if missing:
        fail(f"Configured launcher is unavailable: {command[0]}", 69)
    import shlex
    existing_windows = {window["id"] for window in open_windows()}
    if game["platform"] == "steam":
        existing_steam_state = state.get("Steam")
        started_launcher = not process_running(["steam"])
        if isinstance(existing_steam_state, dict) and existing_steam_state.get("startedLauncher") is True:
            started_launcher = True
        state["Steam"] = {
            "game": game["id"],
            "startedLauncher": started_launcher,
        }
        save_state(state)
    result = subprocess.run(["swaymsg", "exec", "--", shlex.join(command)], capture_output=True, text=True)
    if result.returncode != 0:
        fail(result.stderr.strip() or "Sway rejected the game launch", 69)
    for _ in range(60 if game["platform"] == "heroic" else 30):
        time.sleep(1)
        if game["platform"] == "heroic":
            game_process_ids = heroic_process_ids(game)
            new_windows = [
                window for window in open_windows()
                if window["id"] not in existing_windows
                and window["pid"] in game_process_ids
            ]
            if new_windows:
                # Proton games launched by Heroic use game-specific window
                # classes, so a static Sway rule cannot reliably identify them.
                # These are the new non-Heroic windows created by this launch.
                for window in new_windows:
                    subprocess.run(
                        ["swaymsg", f"[con_id={window['id']}]", "fullscreen", "enable"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                print(json.dumps({"ok": True, "verified": True, "game": public(game)}, separators=(",", ":")))
                return
        if is_running(game):
            if game["platform"] != "steam":
                state[game["launcher"]] = game["id"]
                save_state(state)
            print(json.dumps({"ok": True, "verified": True, "game": public(game)}, separators=(",", ":")))
            return
    fail("The launch was accepted, but the game did not appear", 69)


def close_game(game):
    state = load_state()

    def report_closed():
        response = {"ok": True, "verified": True, "game": public(game)}
        if game["platform"] == "steam":
            steam_state = state.get("Steam")
            started_launcher = (
                isinstance(steam_state, dict)
                and steam_state.get("game") == game["id"]
                and steam_state.get("startedLauncher") is True
            )
            if started_launcher:
                subprocess.run(["steam", "-shutdown"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for _ in range(15):
                    time.sleep(1)
                    if not process_running(["steam"]):
                        break
                response["launcherClosed"] = not process_running(["steam"])
            state.pop("Steam", None)
            save_state(state)
        print(json.dumps(response, separators=(",", ":")))

    if game["platform"] == "heroic":
        game_process_ids = heroic_process_ids(game)
        if not game_process_ids:
            fail("The selected Heroic game is not running", 66)
        closed = False
        for node in walk(sway_tree()):
            if node.get("pid") in game_process_ids and node.get("id"):
                subprocess.run(["swaymsg", f"[con_id={node['id']}]", "kill"], stdout=subprocess.DEVNULL)
                closed = True
        if not closed:
            fail("The selected Heroic game is not running", 66)
        for _ in range(15):
            time.sleep(1)
            if not heroic_is_running(game):
                state.pop("Heroic", None)
                save_state(state)
                print(json.dumps({"ok": True, "verified": True, "game": public(game)}, separators=(",", ":")))
                return
        fail("The close command was sent, but the Heroic game is still running", 69)

    if game["platform"] != "steam" and not is_running(game):
        fail("The selected game is not running", 66)
    if game["platform"] == "steam":
        subprocess.run(["steam", f"steam://stop/{game['appid']}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(5):
            time.sleep(1)
            if not is_running(game):
                report_closed()
                return
    targets = {value.casefold() for value in expected_ids(game)}

    # Emulator game surfaces commonly close back to their main window instead
    # of exiting the application. Close at most two generations of matching
    # windows so one game-control request closes both, while still allowing each
    # generation time to shut down and save cleanly.
    close_rounds = 1 if game["platform"] == "steam" else 2
    for _ in range(close_rounds):
        closed = False
        for node in walk(sway_tree()):
            app_id = node.get("app_id") or (node.get("window_properties") or {}).get("class")
            if app_id and app_id.casefold() in targets and node.get("id"):
                subprocess.run(["swaymsg", f"[con_id={node['id']}]", "kill"], stdout=subprocess.DEVNULL)
                closed = True
        if not closed:
            fail("The selected game is not running", 66)
        for _ in range(15):
            time.sleep(1)
            if not is_running(game):
                if game["platform"] != "steam":
                    state.pop(game["launcher"], None)
                    save_state(state)
                report_closed()
                return
    fail("The close command was sent, but the game is still running", 69)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rom-root", required=True)
    parser.add_argument("--retroarch-core", required=True)
    parser.add_argument("--title-overrides-json", required=True)
    parser.add_argument("action", choices=["list", "search", "launch", "close", "running"])
    parser.add_argument("value", nargs="?")
    args = parser.parse_args()
    if args.action in {"list", "running"} and args.value is not None:
        fail(f"{args.action} does not accept an argument", 2)
    if args.action in {"search", "launch", "close"} and not args.value:
        fail(f"{args.action} requires one argument", 2)

    games = inventory(args)
    if args.action == "list":
        print(json.dumps({"games": [public(game) for game in games], "total": len(games)}, separators=(",", ":")))
    elif args.action == "search":
        matches = search(games, args.value)
        print(json.dumps({"matches": [public(game) for game in matches], "total": len(matches)}, separators=(",", ":")))
    elif args.action == "running":
        ids = open_app_ids()
        running = [
            public(game) for game in games
            if (
                game["platform"] == "steam" and is_running(game, ids)
            ) or (
                game["platform"] == "heroic" and heroic_is_running(game)
            ) or (
                game["platform"] not in {"steam", "heroic"}
                and is_running(game, ids)
            )
        ]
        print(json.dumps({"games": running, "total": len(running)}, separators=(",", ":")))
    else:
        game = find_id(games, args.value)
        if not game:
            fail("Unknown game ID; obtain a current ID from list or search", 64)
        if args.action == "launch":
            launch(game, args)
        else:
            close_game(game)


if __name__ == "__main__":
    main()
