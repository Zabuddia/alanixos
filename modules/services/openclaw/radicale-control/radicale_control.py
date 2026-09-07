#!/usr/bin/env python3
"""Structured calendar/contact CRUD over synchronized vdirs."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sys
import tempfile
import unicodedata
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from icalendar import Calendar, Event
import recurring_ical_events
import vobject


def emit(value):
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"), default=str)
    sys.stdout.write("\n")


def fail(code, message, status=1):
    emit({"ok": False, "error": {"code": code, "message": message}})
    raise SystemExit(status)


def read_input():
    try:
        value = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        fail("invalid_input", f"Expected a JSON object: {error}", 64)
    if not isinstance(value, dict):
        fail("invalid_input", "Expected a JSON object", 64)
    return value


def clean_collection(value):
    if not value or value in {".", ".."} or "/" in value or "\\" in value:
        fail("invalid_collection", "Collection must be one local collection name", 64)
    return value


def existing_collection(root, requested, kind):
    collections = sorted(path.name for path in root.iterdir() if path.is_dir()) if root.exists() else []
    if requested:
        collection = clean_collection(requested)
        if collection not in collections:
            fail(
                "unknown_collection",
                f"{kind} collection does not exist; use the ID returned by the collection-list command",
                66,
            )
        return collection
    if len(collections) == 1:
        return collections[0]
    if not collections:
        fail("not_found", f"No existing {kind} collection is available", 66)
    fail("ambiguous_collection", f"More than one {kind} collection exists; specify an existing collection ID", 66)


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".openclaw-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def decoded(component, name):
    try:
        value = component.decoded(name)
    except (KeyError, AttributeError):
        return None
    return value.isoformat() if hasattr(value, "isoformat") else str(value)


def local_datetime(value, timezone):
    if isinstance(value, dt.datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone)
        return value.astimezone(timezone)
    if isinstance(value, dt.date):
        return dt.datetime.combine(value, dt.time.min, timezone)
    return None


def event_bounds(event, timezone):
    try:
        raw_start = event.decoded("dtstart")
    except (KeyError, AttributeError):
        return None
    start = local_datetime(raw_start, timezone)
    if start is None:
        return None
    all_day = isinstance(raw_start, dt.date) and not isinstance(raw_start, dt.datetime)

    try:
        raw_end = event.decoded("dtend")
    except (KeyError, AttributeError):
        raw_end = None
    end = local_datetime(raw_end, timezone)
    if end is None:
        try:
            duration = event.decoded("duration")
        except (KeyError, AttributeError):
            duration = None
        if isinstance(duration, dt.timedelta):
            end = start + duration
        elif all_day:
            end = start + dt.timedelta(days=1)
        else:
            end = start
    return start, end, all_day


def event_record(path, event, timezone=None):
    bounds = event_bounds(event, timezone) if timezone is not None else None
    if bounds is None:
        start = decoded(event, "dtstart")
        end = decoded(event, "dtend")
        all_day = False
    else:
        start_value, end_value, all_day = bounds
        start = start_value.date().isoformat() if all_day else start_value.isoformat()
        end = end_value.date().isoformat() if all_day else end_value.isoformat()
    return {
        "id": str(event.get("uid", "")),
        "collection": path.parent.name,
        "title": str(event.get("summary", "")),
        "start": start,
        "end": end,
        "allDay": all_day,
        "description": str(event.get("description", "")) or None,
        "location": str(event.get("location", "")) or None,
    }


def calendar_files(root):
    for path in root.glob("*/*.ics"):
        try:
            yield path, Calendar.from_ical(path.read_bytes())
        except Exception:
            continue


def calendar_items(root):
    for path, calendar in calendar_files(root):
        for event in calendar.walk("VEVENT"):
            yield path, calendar, event


def parse_datetime(value, timezone=None):
    if not isinstance(value, str) or not value:
        fail("invalid_input", "start and end must be ISO-8601 strings", 64)
    try:
        if len(value) == 10:
            return dt.date.fromisoformat(value)
        result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None and timezone is not None:
            return result.replace(tzinfo=timezone)
        return result
    except ValueError:
        fail("invalid_input", f"Invalid ISO-8601 date/time: {value}", 64)


def parse_instant(value, timezone):
    result = parse_datetime(value, timezone)
    if isinstance(result, dt.date) and not isinstance(result, dt.datetime):
        return dt.datetime.combine(result, dt.time.min, timezone)
    return result.astimezone(timezone)


def set_event(event, value, creating=False, timezone=None):
    required = ("title", "start") if creating else ()
    for name in required:
        if not value.get(name):
            fail("invalid_input", f"Missing required field: {name}", 64)
    mapping = {"title": "summary", "description": "description", "location": "location"}
    for source, target in mapping.items():
        if source in value:
            if target in event:
                del event[target]
            if value[source] is not None:
                event.add(target, str(value[source]))
    for source, target in (("start", "dtstart"), ("end", "dtend")):
        if source in value:
            if target in event:
                del event[target]
            if value[source] is not None:
                event.add(target, parse_datetime(value[source], timezone))


def occurrence_items(root, start, end, timezone):
    for path, calendar in calendar_files(root):
        try:
            occurrences = recurring_ical_events.of(calendar).between(start, end)
        except Exception:
            continue
        for event in occurrences:
            bounds = event_bounds(event, timezone)
            if bounds is None:
                continue
            event_start, event_end, _ = bounds
            if (event_end > start or event_start >= start) and event_start < end:
                yield path, event


def matching_records(items, query, timezone):
    records = [event_record(path, event, timezone) for path, event in items]
    if query:
        needle = query.casefold()
        records = [record for record in records if needle in json.dumps(record).casefold()]
    return sorted(records, key=lambda record: (record["start"] or "", record["title"].casefold()))


def require_arguments(action, arguments, count, usage):
    if len(arguments) != count:
        fail("invalid_input", f"Usage: radicale-calendar {action} {usage}", 64)


def calendar_command(root, action, arguments, query, timezone):
    if action == "collections":
        require_arguments(action, arguments, 0, "")
        emit({"ok": True, "collections": sorted(p.name for p in root.iterdir() if p.is_dir()) if root.exists() else []})
        return
    items = list(calendar_items(root))
    if action in {"list", "search"}:
        if len(arguments) > 1:
            fail("invalid_input", f"Usage: radicale-calendar {action} [QUERY]", 64)
        records = [event_record(path, event, timezone) for path, _, event in items]
        if query or arguments:
            needle = (query or arguments[0]).casefold()
            records = [r for r in records if needle in json.dumps(r).casefold()]
        emit({"ok": True, "events": records})
        return
    if action == "events":
        require_arguments(action, arguments, 2, "START END [--query QUERY]")
        start = parse_instant(arguments[0], timezone)
        end = parse_instant(arguments[1], timezone)
        if end <= start:
            fail("invalid_input", "END must be after START", 64)
        records = matching_records(occurrence_items(root, start, end, timezone), query, timezone)
        emit({"ok": True, "range": {"start": start.isoformat(), "end": end.isoformat()}, "events": records})
        return
    if action == "next":
        if len(arguments) > 1:
            fail("invalid_input", "Usage: radicale-calendar next [START] [--query QUERY]", 64)
        start = parse_instant(arguments[0], timezone) if arguments else dt.datetime.now(timezone)
        found = []
        window_start = start
        for _ in range(10):
            window_end = window_start + dt.timedelta(days=366)
            found = matching_records(occurrence_items(root, window_start, window_end, timezone), query, timezone)
            found = [record for record in found if parse_instant(record["start"], timezone) >= start]
            if found:
                break
            window_start = window_end
        emit({"ok": True, "from": start.isoformat(), "event": found[0] if found else None})
        return
    if action == "at":
        require_arguments(action, arguments, 1, "TIME [--query QUERY]")
        instant = parse_instant(arguments[0], timezone)
        records = matching_records(
            occurrence_items(root, instant, instant + dt.timedelta(microseconds=1), timezone), query, timezone
        )
        emit({"ok": True, "time": instant.isoformat(), "available": not records, "conflicts": records})
        return
    if action == "free":
        require_arguments(action, arguments, 3, "START END MINUTES [--query QUERY]")
        start = parse_instant(arguments[0], timezone)
        end = parse_instant(arguments[1], timezone)
        if end <= start:
            fail("invalid_input", "END must be after START", 64)
        try:
            duration_minutes = int(arguments[2])
        except ValueError:
            fail("invalid_input", "MINUTES must be a positive integer", 64)
        if duration_minutes <= 0:
            fail("invalid_input", "MINUTES must be a positive integer", 64)
        records = matching_records(occurrence_items(root, start, end, timezone), query, timezone)
        busy = []
        for record in records:
            event_start = max(start, parse_instant(record["start"], timezone))
            event_end = min(end, parse_instant(record["end"], timezone))
            if event_end > event_start:
                busy.append((event_start, event_end))
        merged = []
        for event_start, event_end in sorted(busy):
            if merged and event_start <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], event_end))
            else:
                merged.append((event_start, event_end))
        free_windows = []
        cursor = start
        minimum = dt.timedelta(minutes=duration_minutes)
        for event_start, event_end in merged:
            if event_start - cursor >= minimum:
                free_windows.append({"start": cursor.isoformat(), "end": event_start.isoformat()})
            cursor = max(cursor, event_end)
        if end - cursor >= minimum:
            free_windows.append({"start": cursor.isoformat(), "end": end.isoformat()})
        first = None
        if free_windows:
            first_start = parse_instant(free_windows[0]["start"], timezone)
            first = {"start": first_start.isoformat(), "end": (first_start + minimum).isoformat()}
        emit({
            "ok": True,
            "range": {"start": start.isoformat(), "end": end.isoformat()},
            "durationMinutes": duration_minutes,
            "available": bool(free_windows),
            "firstAvailable": first,
            "freeWindows": free_windows,
            "conflicts": records,
        })
        return
    if action == "create":
        if len(arguments) > 1:
            fail("invalid_input", "Usage: radicale-calendar create [COLLECTION_ID]", 64)
        value = read_input()
        requested_collection = value.pop("collection", arguments[0] if arguments else "")
        collection = existing_collection(root, requested_collection, "calendar")
        uid = str(value.pop("id", "") or uuid.uuid4())
        event = Event()
        event.add("uid", uid)
        event.add("dtstamp", dt.datetime.now(dt.timezone.utc))
        set_event(event, value, True, timezone)
        calendar = Calendar()
        calendar.add("prodid", "-//Alanix OpenClaw//EN")
        calendar.add("version", "2.0")
        calendar.add_component(event)
        path = root / collection / f"{uid}.ics"
        if path.exists():
            fail("conflict", "An event with that ID already exists", 73)
        atomic_write(path, calendar.to_ical())
        emit({"ok": True, "event": event_record(path, event, timezone)})
        return
    require_arguments(action, arguments, 1, "ID")
    identifier = arguments[0]
    matches = [
        (path, calendar, event)
        for path, calendar, event in items
        if str(event.get("uid", "")) == identifier and event.get("recurrence-id") is None
    ]
    if len(matches) != 1:
        fail("not_found" if not matches else "conflict", f"Expected one event with ID {identifier}; found {len(matches)}", 66)
    path, calendar, event = matches[0]
    if action == "get":
        emit({"ok": True, "event": event_record(path, event, timezone)})
    elif action == "update":
        set_event(event, read_input(), timezone=timezone)
        atomic_write(path, calendar.to_ical())
        emit({"ok": True, "event": event_record(path, event, timezone)})
    elif action == "delete":
        path.unlink()
        emit({"ok": True, "deleted": {"id": identifier, "collection": path.parent.name}})


def values(card, name):
    return [str(item.value) for item in card.contents.get(name, [])]


def contact_record(path, card):
    return {
        "id": values(card, "uid")[0] if values(card, "uid") else path.stem,
        "addressbook": path.parent.name,
        "name": values(card, "fn")[0] if values(card, "fn") else "",
        "emails": values(card, "email"),
        "phones": values(card, "tel"),
        "organization": values(card, "org")[0] if values(card, "org") else None,
        "note": values(card, "note")[0] if values(card, "note") else None,
    }


def normalized_name(value):
    return " ".join(unicodedata.normalize("NFKC", str(value)).casefold().split())


def contact_items(root):
    for path in root.glob("*/*.vcf"):
        try:
            yield path, vobject.readOne(path.read_text())
        except Exception:
            continue


def replace_values(card, name, value):
    card.contents.pop(name, None)
    if value is None:
        return
    for item in value if isinstance(value, list) else [value]:
        card.add(name).value = str(item)


def set_contact(card, value, creating=False):
    if creating and not value.get("name"):
        fail("invalid_input", "Missing required field: name", 64)
    if "name" in value and (not isinstance(value["name"], str) or not value["name"].strip()):
        fail("invalid_input", "name must be a non-empty string", 64)
    for field in ("emails", "phones"):
        if field not in value or value[field] is None:
            continue
        entries = value[field] if isinstance(value[field], list) else [value[field]]
        if not all(isinstance(entry, str) and entry.strip() for entry in entries):
            fail("invalid_input", f"{field} must be a string or a list of non-empty strings", 64)
    for field in ("organization", "note"):
        if field in value and value[field] is not None and not isinstance(value[field], str):
            fail("invalid_input", f"{field} must be a string or null", 64)
    for source, target in (("name", "fn"), ("emails", "email"), ("phones", "tel"), ("organization", "org"), ("note", "note")):
        if source in value:
            replace_values(card, target, value[source])


def contact_command(root, action, identifier, query):
    if action == "addressbooks":
        emit({"ok": True, "addressbooks": sorted(p.name for p in root.iterdir() if p.is_dir()) if root.exists() else []})
        return
    items = list(contact_items(root))
    records = sorted(
        (contact_record(path, card) for path, card in items),
        key=lambda record: (normalized_name(record["name"]), record["id"]),
    )
    if action == "find":
        requested_name = query or identifier
        if not requested_name:
            fail("invalid_input", "find requires a contact name", 64)
        exact = [record for record in records if normalized_name(record["name"]) == normalized_name(requested_name)]
        partial = [
            record
            for record in records
            if normalized_name(requested_name) in normalized_name(record["name"])
        ]
        matches = exact if exact else partial
        emit({
            "ok": True,
            "query": requested_name,
            "matchType": "exact" if exact else "partial" if partial else "none",
            "ambiguous": len(matches) > 1,
            "match": matches[0] if len(matches) == 1 else None,
            "matches": matches,
        })
        return
    if action in {"list", "search"}:
        if query or identifier:
            needle = (query or identifier).casefold()
            records = [r for r in records if needle in json.dumps(r).casefold()]
        emit({"ok": True, "contacts": records})
        return
    if action == "create":
        value = read_input()
        addressbook = existing_collection(root, value.pop("addressbook", identifier), "address-book")
        name = value.get("name")
        if isinstance(name, str):
            duplicates = [record for record in records if normalized_name(record["name"]) == normalized_name(name)]
            if duplicates:
                fail("conflict", f"A contact named {name} already exists; update the existing contact instead", 73)
        uid = str(value.pop("id", "") or uuid.uuid4())
        card = vobject.vCard()
        card.add("uid").value = uid
        set_contact(card, value, True)
        path = root / addressbook / f"{uid}.vcf"
        if path.exists():
            fail("conflict", "A contact with that ID already exists", 73)
        atomic_write(path, card.serialize().encode())
        emit({"ok": True, "contact": contact_record(path, card)})
        return
    matches = [(p, c) for p, c in items if contact_record(p, c)["id"] == identifier]
    if len(matches) != 1:
        fail("not_found" if not matches else "conflict", f"Expected one contact with ID {identifier}; found {len(matches)}", 66)
    path, card = matches[0]
    if action == "get":
        emit({"ok": True, "contact": contact_record(path, card)})
    elif action == "update":
        set_contact(card, read_input())
        atomic_write(path, card.serialize().encode())
        emit({"ok": True, "contact": contact_record(path, card)})
    elif action == "delete":
        path.unlink()
        emit({"ok": True, "deleted": {"id": identifier, "addressbook": path.parent.name}})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--calendar-root", type=Path, required=True)
    parser.add_argument("--contact-root", type=Path, required=True)
    parser.add_argument("kind", choices=("calendar", "contact"))
    parser.add_argument("action")
    parser.add_argument("arguments", nargs="*")
    parser.add_argument("--query", default="")
    parser.add_argument("--timezone", default="UTC")
    args = parser.parse_args()
    allowed = {
        "calendar": {"collections", "list", "search", "events", "next", "at", "free", "get", "create", "update", "delete"},
        "contact": {"addressbooks", "list", "search", "find", "get", "create", "update", "delete"},
    }
    if args.action not in allowed[args.kind]:
        fail("invalid_operation", f"Unsupported {args.kind} operation: {args.action}", 64)
    if args.kind == "calendar":
        try:
            timezone = ZoneInfo(args.timezone)
        except ZoneInfoNotFoundError:
            fail("invalid_timezone", f"Unknown timezone: {args.timezone}", 64)
        calendar_command(args.calendar_root, args.action, args.arguments, args.query, timezone)
    else:
        if len(args.arguments) > 1:
            fail("invalid_input", f"{args.action} accepts at most one ID, address book, or query", 64)
        identifier = args.arguments[0] if args.arguments else ""
        if args.action in {"get", "update", "delete"} and not identifier:
            fail("invalid_input", f"{args.action} requires an ID or address book", 64)
        contact_command(args.contact_root, args.action, identifier, args.query)


if __name__ == "__main__":
    main()
