#!/usr/bin/env python3
"""Structured calendar/contact CRUD over synchronized vdirs."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid

from icalendar import Calendar, Event
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


def event_record(path, event):
    return {
        "id": str(event.get("uid", "")),
        "collection": path.parent.name,
        "title": str(event.get("summary", "")),
        "start": decoded(event, "dtstart"),
        "end": decoded(event, "dtend"),
        "description": str(event.get("description", "")) or None,
        "location": str(event.get("location", "")) or None,
    }


def calendar_items(root):
    for path in root.glob("*/*.ics"):
        try:
            calendar = Calendar.from_ical(path.read_bytes())
            for event in calendar.walk("VEVENT"):
                yield path, calendar, event
        except Exception:
            continue


def parse_datetime(value):
    if not isinstance(value, str) or not value:
        fail("invalid_input", "start and end must be ISO-8601 strings", 64)
    try:
        if len(value) == 10:
            return dt.date.fromisoformat(value)
        result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return result.astimezone(dt.timezone.utc) if result.tzinfo is not None else result
    except ValueError:
        fail("invalid_input", f"Invalid ISO-8601 date/time: {value}", 64)


def set_event(event, value, creating=False):
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
                event.add(target, parse_datetime(value[source]))


def calendar_command(root, action, identifier, query):
    if action == "collections":
        emit({"ok": True, "collections": sorted(p.name for p in root.iterdir() if p.is_dir()) if root.exists() else []})
        return
    items = list(calendar_items(root))
    if action in {"list", "search"}:
        records = [event_record(path, event) for path, _, event in items]
        if query or identifier:
            needle = (query or identifier).casefold()
            records = [r for r in records if needle in json.dumps(r).casefold()]
        emit({"ok": True, "events": records})
        return
    if action == "create":
        value = read_input()
        collection = clean_collection(value.pop("collection", identifier))
        uid = str(value.pop("id", "") or uuid.uuid4())
        event = Event()
        event.add("uid", uid)
        event.add("dtstamp", dt.datetime.now(dt.timezone.utc))
        set_event(event, value, True)
        calendar = Calendar()
        calendar.add("prodid", "-//Alanix OpenClaw//EN")
        calendar.add("version", "2.0")
        calendar.add_component(event)
        path = root / collection / f"{uid}.ics"
        if path.exists():
            fail("conflict", "An event with that ID already exists", 73)
        atomic_write(path, calendar.to_ical())
        emit({"ok": True, "event": event_record(path, event)})
        return
    matches = [(p, c, e) for p, c, e in items if str(e.get("uid", "")) == identifier]
    if len(matches) != 1:
        fail("not_found" if not matches else "conflict", f"Expected one event with ID {identifier}; found {len(matches)}", 66)
    path, calendar, event = matches[0]
    if action == "get":
        emit({"ok": True, "event": event_record(path, event)})
    elif action == "update":
        set_event(event, read_input())
        atomic_write(path, calendar.to_ical())
        emit({"ok": True, "event": event_record(path, event)})
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
    for source, target in (("name", "fn"), ("emails", "email"), ("phones", "tel"), ("organization", "org"), ("note", "note")):
        if source in value:
            replace_values(card, target, value[source])


def contact_command(root, action, identifier, query):
    if action == "addressbooks":
        emit({"ok": True, "addressbooks": sorted(p.name for p in root.iterdir() if p.is_dir()) if root.exists() else []})
        return
    items = list(contact_items(root))
    if action in {"list", "search"}:
        records = [contact_record(path, card) for path, card in items]
        if query or identifier:
            needle = (query or identifier).casefold()
            records = [r for r in records if needle in json.dumps(r).casefold()]
        emit({"ok": True, "contacts": records})
        return
    if action == "create":
        value = read_input()
        addressbook = clean_collection(value.pop("addressbook", identifier))
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
    parser.add_argument("identifier", nargs="?", default="")
    parser.add_argument("--query", default="")
    args = parser.parse_args()
    allowed = {"calendar": {"collections", "list", "search", "get", "create", "update", "delete"}, "contact": {"addressbooks", "list", "search", "get", "create", "update", "delete"}}
    if args.action not in allowed[args.kind]:
        fail("invalid_operation", f"Unsupported {args.kind} operation: {args.action}", 64)
    if args.action in {"get", "create", "update", "delete"} and not args.identifier:
        fail("invalid_input", f"{args.action} requires an ID or collection", 64)
    if args.kind == "calendar":
        calendar_command(args.calendar_root, args.action, args.identifier, args.query)
    else:
        contact_command(args.contact_root, args.action, args.identifier, args.query)


if __name__ == "__main__":
    main()
