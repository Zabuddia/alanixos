# Jarvis Acceptance Tests

This file is the master end-to-end acceptance-test checklist for the Home Assistant + OpenClaw "Jarvis" setup.

The goal is simple: **do not mark a command as passing until the exact test phrase works end-to-end when spoken or typed to Jarvis.**


---

## Routing Labels

Every test is explicitly labeled with the path it should use.

- **`[LOCAL / Home Assistant]`** — should be handled by Home Assistant/local intents without sending the request to the LLM when practical.
- **`[LLM / OpenClaw]`** — should intentionally route to OpenClaw because it requires reasoning, searching, another self-hosted service, computer control, cross-tool behavior, or capabilities not handled directly by Home Assistant.

If a `[LOCAL / Home Assistant]` command works but unnecessarily routes through OpenClaw, do **not** mark the routing test as passing.

---

# 1. Home Assistant Lights

There are currently two simple on/off lights:

- Living Room Light
- Hallway Light

No brightness control is required.

### Home Assistant setup required

The physical Zigbee devices were originally exposed by ZHA as switches. Home Assistant could control each one by name, but commands such as **"Turn on all lights"** did not match locally because there were no exposed entities in the `light` domain. The unmatched command therefore fell through to OpenClaw.

To make Home Assistant's built-in light intents work, create a **Change device type of a switch** (`Switch as X`) helper for each switch:

- `switch.living_room_light` → `light.living_room_light`
- `switch.hallway_light` → `light.hallway_light`

Expose the two `light.*` helpers to Assist, and hide and unexpose the underlying `switch.*` entities. The light helpers and the Home Assistant Voice PE must be assigned to the same **Living Room** area so area-relative commands are handled locally. These helpers and their Assist exposure settings are managed in Home Assistant, not in the NixOS configuration.

## 1.1 Living Room Light

- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn on/off living room light."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn living room light on/off."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Is living room light on/off?"**

## 1.2 Hallway Light

- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn on/off hallway light."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn hallway light on/off."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Is hallway light on/off?"**

## 1.3 All Lights

- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn on/off all lights."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn lights on/off."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Are all lights on/off?"**

---

# 2. Physical TV / Pulse-Eight CEC

The physical TV is controlled through a Pulse-Eight USB-CEC adapter connected to the media PC.

Only power and power-state reporting are required for now.

### Home Assistant setup required

The media PC sends TV power commands and reports the observed CEC power state to Home Assistant through MQTT. Add the MQTT integration, rename the discovered power entity to `switch.tv` with the name **TV**, assign its device to **Living Room**, and expose only `switch.tv` to Assist.

The MQTT power entity must have the `switch` device class so Home Assistant's built-in TV on/off intents accept it. No custom Assist sentences are needed; old TV sentences must be removed so they do not override the built-in intents with stale entity names.

- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn on/off the TV."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn the TV on/off"**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Is the TV on/off?"**

### State verification

- [x] If the TV is turned on with its physical remote, Home Assistant eventually reports it as on.
- [x] If the TV is turned off with its physical remote, Home Assistant eventually reports it as off.

---

# 3. Kodi on the Media PC

Kodi runs on the computer attached to the TV.

These tests are about controlling Kodi itself, not directly controlling Jellyfin/Navidrome/Audiobookshelf.

**Default media-control rule:** if a media-control command does not explicitly name a device or playback target, Home Assistant should apply it to **Kodi on `alan-tv`**. These short default commands should remain **LOCAL / Home Assistant** and should not require OpenClaw.

### Home Assistant setup required

The following entity-registry settings are managed in the Home Assistant UI:

- Assign the MQTT `switch.kodi` entity to **Living Room**, add the alias **Cody**, and expose it to Assist.
- Rename the Kodi integration's media-player entity to **Kodi** and set its entity ID to `media_player.living_room_kodi`.
- Assign `media_player.living_room_kodi` to **Living Room** and expose it to Assist.

Keep both entities exposed. `switch.kodi` controls whether the Kodi application is running, while `media_player.living_room_kodi` provides playback state and controls.

## 3.0 Kodi Application

- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn Kodi on/off."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Is Kodi on/off?"**

## 3.1 Kodi Playback State

- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What is playing?"**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Pause/Stop."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Unpause/Resume."**

Expected target for every command above when no target is named: **Kodi on `alan-tv`**.

## 3.2 Kodi Subtitles

- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn on subtitles."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn off subtitles."**

Expected target when no target is named: **Kodi on `alan-tv`**.

## 3.3 Kodi Mute and Volume

- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Mute."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Unmute."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn the volume up."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn the volume down."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Set the volume to fifty percent."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What is the volume?"**

Expected target for every command above when no target is named: **Kodi on `alan-tv`**.

## 3.4 Kodi Metadata

When media is playing, Kodi should expose enough information for Jarvis to report useful metadata.

- [ ] Correctly reports movie title when a movie is playing.
- [ ] Correctly reports TV show, season, and episode when an episode is playing.
- [ ] Correctly reports song title and artist when music is playing.
- [ ] Correctly reports audiobook/book information when available through the add-on/player.
- [ ] Correctly distinguishes playing, paused, and stopped.

---

# 4. Jellyfin

Primary playback for now is through the **Jellyfin Kodi add-on**. A Home Assistant Jellyfin integration is not required.

OpenClaw should also be able to query Jellyfin directly so it can inspect the library and, if practical, see activity from Jellyfin clients other than Kodi.

## 4.1 Jellyfin Library Queries

- [ ] **[LLM / OpenClaw]** Say exactly: **"Do I have the movie The Incredibles in Jellyfin?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Do I have the TV show Severance in Jellyfin?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"List my Jellyfin movies named Harry Potter."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"List the episodes of season one of Severance in Jellyfin."**

## 4.2 Jellyfin Playback Through Kodi

The request explicitly states the media type to reduce ambiguity.

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the movie The Incredibles from Jellyfin on Kodi."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the TV show Severance season one episode three from Jellyfin on Kodi."**

Expected behavior:

1. If the media PC must be awake, wake it first.
2. Use Kodi as the playback target.
3. Use the Jellyfin Kodi add-on/library path as needed.
4. Verify that playback actually begins.

## 4.3 Jellyfin Activity Outside Kodi

These are direct Jellyfin/OpenClaw capabilities and may be implemented later if the Jellyfin API exposes the needed state cleanly.

- [ ] **[LLM / OpenClaw]** Say exactly: **"Is anyone currently playing anything from Jellyfin?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What is currently playing from Jellyfin?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Which Jellyfin client is currently playing media?"**

---

# 5. Navidrome

Playback for now is primarily through a Kodi/Navidrome add-on or Kodi-visible music source.

OpenClaw should also be able to inspect the Navidrome library independently from Kodi.

## 5.1 Navidrome Library Queries

- [ ] **[LLM / OpenClaw]** Say exactly: **"Do I have the song Believer by Imagine Dragons in Navidrome?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"List my songs by Imagine Dragons in Navidrome."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"List my albums by Imagine Dragons in Navidrome."**

## 5.2 Navidrome Playback Through Kodi

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the song Believer by Imagine Dragons from Navidrome on Kodi."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the album Evolve by Imagine Dragons from Navidrome on Kodi."**

## 5.3 Lyrics

OpenClaw may use lyrics metadata available through Navidrome or another configured source, but the request should be tied to a song in the user's library.

- [ ] **[LLM / OpenClaw]** Say exactly: **"Show me the lyrics for the song Believer by Imagine Dragons in my Navidrome library."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What song is currently playing on Kodi, and do I have lyrics for it in Navidrome?"**

---

# 6. Audiobookshelf

Playback for now is primarily through the Audiobookshelf Kodi add-on.

OpenClaw should also connect directly to Audiobookshelf for library and progress information.

## 6.1 Audiobookshelf Library

- [ ] **[LLM / OpenClaw]** Say exactly: **"Do I have the book Harry Potter and the Sorcerer's Stone in Audiobookshelf?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"List my books in Audiobookshelf."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What Audiobookshelf books am I currently in progress on?"**

## 6.2 Audiobook Progress

- [ ] **[LLM / OpenClaw]** Say exactly: **"What is my progress in the book Harry Potter and the Sorcerer's Stone in Audiobookshelf?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"How much time is left in the book Harry Potter and the Sorcerer's Stone in Audiobookshelf?"**

## 6.3 Audiobookshelf Playback Through Kodi

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the book Harry Potter and the Sorcerer's Stone from Audiobookshelf on Kodi."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Resume the book Harry Potter and the Sorcerer's Stone from Audiobookshelf on Kodi."**

---

# 7. Explicit Unified Media Commands

To avoid ambiguity, **always specify the media type** in tests: movie, TV show, song, album, or book.

Do not rely on Jarvis guessing whether "Harry Potter" means a movie, book, soundtrack, etc.

## 7.1 Movies

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the movie The Incredibles on Kodi."**

Expected default media source: Jellyfin.

## 7.2 TV Shows

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the TV show Severance season one episode three on Kodi."**

Expected default media source: Jellyfin.

## 7.3 Songs

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the song Believer by Imagine Dragons on Kodi."**

Expected default media source: Navidrome.

## 7.4 Albums

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the album Evolve by Imagine Dragons on Kodi."**

Expected default media source: Navidrome.

## 7.5 Books

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the book Harry Potter and the Sorcerer's Stone on Kodi."**

Expected default media source: Audiobookshelf.

---

# 8. Calendar / Radicale

## 8.1 Read Calendar

- [ ] **[LLM / OpenClaw]** Say exactly: **"What events are on my calendar today?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What events are on my calendar tomorrow?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What events are on my calendar this week?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What is my next calendar event?"**

## 8.2 Check Availability

- [ ] **[LLM / OpenClaw]** Say exactly: **"Am I free this Friday at three PM?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Find a one-hour free period on my calendar tomorrow afternoon."**

## 8.3 Create Calendar Events

Use a disposable test event when testing CRUD.

- [ ] **[LLM / OpenClaw]** Say exactly: **"Create a calendar event named Jarvis Test Event tomorrow at three PM for one hour."**
- [ ] Confirm it was actually created in Radicale.

## 8.4 Update Calendar Events

- [ ] **[LLM / OpenClaw]** Say exactly: **"Move the calendar event Jarvis Test Event tomorrow from three PM to four PM."**
- [ ] Confirm the existing event was updated rather than duplicated.

## 8.5 Delete Calendar Events

- [ ] **[LLM / OpenClaw]** Say exactly: **"Delete the calendar event Jarvis Test Event tomorrow at four PM."**
- [ ] Confirm it was actually removed.

---

# 9. Contacts / Radicale

Use a disposable contact for create/update/delete testing.

## 9.1 Read Contacts

- [ ] **[LLM / OpenClaw]** Say exactly: **"Find the contact named Jarvis Test Contact."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What is the phone number for Jarvis Test Contact?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What is the email address for Jarvis Test Contact?"**

## 9.2 Create Contact

- [ ] **[LLM / OpenClaw]** Say exactly: **"Create a contact named Jarvis Test Contact with phone number 214-555-0100 and email address jarvis-test@example.com."**
- [ ] Confirm it actually exists in Radicale.

## 9.3 Update Contact

- [ ] **[LLM / OpenClaw]** Say exactly: **"Change the phone number for Jarvis Test Contact to 214-555-0101."**
- [ ] Confirm the existing contact was edited rather than duplicated.

## 9.4 Delete Contact

- [ ] **[LLM / OpenClaw]** Say exactly: **"Delete the contact named Jarvis Test Contact."**
- [ ] Confirm it was actually removed.

---

# 10. Contacts + Other Tools

Cross-tool contact resolution is essential.

Once contact and email functionality are independently passing, test these.

- [ ] **[LLM / OpenClaw]** Say exactly: **"Find the email address for Jarvis Test Contact and draft an email to that address saying this is a Jarvis test."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Find the email address for Jarvis Test Contact and send an email saying this is a Jarvis contact-resolution test."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Create a calendar event named Meeting With Jarvis Test Contact tomorrow at two PM for one hour."**

For destructive/external tests, use a real disposable test contact/email address you control instead of the example address above.

---

# 11. Computer Control

For computer-control commands, the preferred behavior is:

- If the user **explicitly names a computer**, operate on that computer.
- If no computer is specified, use the configured default computer.
- Current default computer: `alan-tv`.

## 11.1 Online / Status

- [ ] **[LLM / OpenClaw]** Say exactly: **"Is alan-framework-laptop online?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Which of my computers are currently online?"**

## 11.2 List Apps / Windows

- [ ] **[LLM / OpenClaw]** Say exactly: **"List the open applications on alan-framework-laptop."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"List the open applications on the default computer."**

## 11.3 Open Applications

- [ ] **[LLM / OpenClaw]** Say exactly: **"Open Firefox on alan-framework-laptop."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Open Kodi on the default computer."**

## 11.4 Close Applications

- [ ] **[LLM / OpenClaw]** Say exactly: **"Close Firefox on alan-framework-laptop."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Close Kodi on the default computer."**

## 11.5 Screen Inspection

- [ ] **[LLM / OpenClaw]** Say exactly: **"Take a screenshot of alan-framework-laptop and describe what is on the screen."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Take a screenshot of the default computer and describe what is on the screen."**

## 11.6 Clipboard

- [ ] **[LLM / OpenClaw]** Say exactly: **"Read the clipboard on alan-framework-laptop."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Set the clipboard on alan-framework-laptop to Jarvis clipboard test."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Read the clipboard on the default computer."**

---

# 12. Browser Control

## 12.1 Open / Read Pages

- [ ] **[LLM / OpenClaw]** Say exactly: **"Open example.com in the browser and tell me the page title."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Open the NixOS website in the browser and summarize the home page."**

## 12.2 Search

- [ ] **[LLM / OpenClaw]** Say exactly: **"Use the browser to search the web for the NixOS Home Manager manual and tell me the title of the official result."**

## 12.3 Page Interaction

Use a harmless page specifically chosen for testing before adding site-specific workflows.

- [ ] **[LLM / OpenClaw]** Open a test page, click a specified link/button, and report the resulting page.
- [ ] **[LLM / OpenClaw]** Fill a non-sensitive test form and verify the submitted values.

**Exact test phrase:** _TODO: choose a stable test page before implementation._

---

# 13. File Access

OpenClaw should have **unrestricted filesystem access** on machines where its tool is intentionally installed/configured.

It should also have especially convenient access to the Filebrowser/Syncthing folder because that is a common working area.

## 13.1 General Filesystem

- [ ] **[LLM / OpenClaw]** Say exactly: **"List the files in slash tmp on the default computer."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Create a file named slash tmp slash jarvis-test.txt on the default computer containing the text Jarvis file test."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Read slash tmp slash jarvis-test.txt on the default computer."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Change slash tmp slash jarvis-test.txt on the default computer so it contains the text Jarvis file test updated."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Delete slash tmp slash jarvis-test.txt on the default computer."**

## 13.2 Filebrowser / Syncthing Folder

Replace `<FILEBROWSER_FOLDER>` with the actual configured path once finalized.

- [ ] **[LLM / OpenClaw]** Say exactly: **"List the files in my Filebrowser folder."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Tell me what is in the file named Jarvis Test.txt in my Filebrowser folder."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Create a file named Jarvis Test.txt in my Filebrowser folder containing the text Filebrowser integration works."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Append the text OpenClaw edited this file to Jarvis Test.txt in my Filebrowser folder."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Delete Jarvis Test.txt from my Filebrowser folder."**

---

# 14. Self-Hosted Email — fifefin.com

All email tests should use the self-hosted `fifefin.com` mail system unless this document is changed later.

Use a test mailbox/contact you control for send/reply tests.

## 14.1 Read / Search Email

- [ ] **[LLM / OpenClaw]** Say exactly: **"List my five newest emails in my fifefin.com mailbox."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"List my unread emails in my fifefin.com mailbox."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Find emails in my fifefin.com mailbox with Jarvis Test in the subject."**

## 14.2 Draft Email

- [ ] **[LLM / OpenClaw]** Say exactly: **"Draft an email from my fifefin.com account to TEST_EMAIL with subject Jarvis Test and body This is a Jarvis email test. Do not send it."**
- [ ] Confirm a draft exists and has the exact intended recipient, subject, and body.

## 14.3 Send Email

- [ ] **[LLM / OpenClaw]** Say exactly: **"Send an email from my fifefin.com account to TEST_EMAIL with subject Jarvis Send Test and body This is a Jarvis send test."**
- [ ] Confirm receipt at the test mailbox.

## 14.4 Reply

- [ ] Send a test message to the fifefin.com account with subject `Jarvis Reply Test`.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Reply to the newest email with subject Jarvis Reply Test and say This is the Jarvis reply."**
- [ ] Confirm the reply remains in the original email thread.

## 14.5 Mail Management

- [ ] **[LLM / OpenClaw]** Say exactly: **"Mark the newest email with subject Jarvis Test as read."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Archive the newest email with subject Jarvis Test."**

---

# 15. XMPP / Prosody

## 15.1 Send Message

- [ ] **[LLM / OpenClaw]** Say exactly: **"Send the XMPP account TEST_XMPP the message This is a Jarvis XMPP test."**
- [ ] Confirm the message arrives.

## 15.2 Read Messages

- [ ] Send a test message to the user's XMPP account.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Read my newest XMPP message."**

## 15.3 Reply

- [ ] **[LLM / OpenClaw]** Say exactly: **"Reply to my newest XMPP message and say This is the Jarvis XMPP reply."**

## 15.4 Talk to Jarvis Through XMPP

- [ ] Send Jarvis an XMPP message containing exactly: **"Is the TV on?"**
- [ ] Jarvis receives and processes the message.
- [ ] It uses the same Home Assistant/OpenClaw tool stack as another Jarvis interface.
- [ ] The answer is sent back through XMPP.

---

# 16. Maps / Places / Location Awareness

OpenClaw should know the user's configured home address/location without requiring the address to be repeated on every request.

Store the home address in an appropriate private configuration/secret source rather than hard-coding it into this public repo if the repository is public.

- [ ] Home address/location is available to OpenClaw through configuration.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Find the nearest Walmart to my home address."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"How far is the nearest Walmart from my home address?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Find three restaurants within five miles of my home address."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What is the address of the nearest Home Depot to my home address?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is the nearest Walmart to my home address open right now?"**

---

# 17. Bitcoin / Node Status

Keep Bitcoin functionality read-only unless explicitly expanded later.

- [ ] **[LLM / OpenClaw]** Say exactly: **"What is the current Bitcoin block height on my node?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Bitcoin Core on my node fully synchronized?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Fulcrum on my node fully synchronized?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is my Electrum server running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is my Lightning node running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What is the Bitcoin balance reported by my read-only Bitcoin tools?"**

---

# 18. System / Service Status

OpenClaw should be able to inspect known hosts and services.

- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Jellyfin running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Navidrome running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Audiobookshelf running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Home Assistant running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is my Prosody XMPP server running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Which of my configured computers are offline?"**

## 18.1 Service Logs / Diagnosis

- [ ] **[LLM / OpenClaw]** Say exactly: **"Show me the recent errors from the Jellyfin service."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Tell me why the Navidrome service is not running."**

Run failure-path tests against a disposable/test service where possible instead of deliberately breaking production services.

---

# 19. AdGuard Home

Use Home Assistant directly for capabilities that its AdGuard integration already exposes cleanly. Use OpenClaw only for queries/actions that require deeper inspection outside HA.

- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Is AdGuard Home enabled?"**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn off AdGuard Home filtering."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn on AdGuard Home filtering."**

If detailed statistics are not available as HA intents, route them through OpenClaw:

- [ ] **[LLM / OpenClaw]** Say exactly: **"How many DNS requests has AdGuard Home blocked today?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is raw.githubusercontent.com currently being blocked by AdGuard Home?"**

---

# 20. Wake-on-LAN / Automatic Computer Wake

Jarvis should be able to wake any explicitly named configured computer.

- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Wake alan-framework-laptop."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn on alan-framework-laptop."**

If Home Assistant does not expose a given computer's WOL switch cleanly, that specific host may instead use OpenClaw; prefer Home Assistant when possible.

## 20.1 Automatic Wake as Part of Another Task

When a requested task requires a computer that is currently off, Jarvis should wake it first and then continue the original task.

- [ ] Turn off a test computer that supports WOL.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Open Firefox on alan-framework-laptop."**
- [ ] Jarvis detects that `alan-framework-laptop` is offline.
- [ ] Jarvis sends the configured Wake-on-LAN action.
- [ ] Jarvis waits/checks until the computer is reachable.
- [ ] Jarvis opens Firefox after the machine becomes available.

---

# 21. Weather / Time

Prefer Home Assistant/local integrations for simple deterministic weather/time queries when those intents are available.

- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What is the weather at home?"**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What is the weather forecast at home tomorrow?"**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What time is it in London?"**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What is today's date?"**

---

# 22. Cross-Tool Workflows

Do these only after the underlying individual tools pass.

## 22.1 Contact → Email

- [ ] **[LLM / OpenClaw]** Say exactly: **"Find TEST_CONTACT in my contacts and send that contact an email from my fifefin.com account with subject Jarvis Cross Tool Test and body This is a cross-tool test."**

Expected chain:

Contacts → resolve email address → fifefin.com mail → send → report actual send result.

## 22.2 Email → Calendar

Create a test email containing an explicit date/time first.

- [ ] **[LLM / OpenClaw]** Say exactly: **"Read the newest email with subject Jarvis Meeting Test and create the meeting described in that email on my calendar."**

Expected chain:

Email → extract event → calendar → create event → verify.

## 22.3 Media + Automatic Wake

With the media PC powered off:

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the movie The Incredibles from Jellyfin on Kodi."**

Expected chain:

Detect media PC offline → wake media PC → wait for Kodi/tool availability → locate Jellyfin movie → start playback → verify playback.

---

# 23. Failure / Truthfulness Tests

These tests ensure Jarvis does not claim success merely because it attempted an action.

## 23.1 Offline Computer

- [ ] Choose a computer that is intentionally offline and cannot currently be woken.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Open Firefox on OFFLINE_TEST_COMPUTER."**
- [ ] Jarvis reports that the computer is unavailable instead of claiming Firefox opened.

## 23.2 Missing Media

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the movie Jarvis Definitely Missing Movie 987654 from Jellyfin on Kodi."**
- [ ] Jarvis reports that the movie could not be found.
- [ ] Jarvis does not claim playback started.

## 23.3 Missing Contact

- [ ] **[LLM / OpenClaw]** Say exactly: **"Find the phone number for Jarvis Definitely Missing Contact 987654."**
- [ ] Jarvis reports no matching contact.

## 23.4 Failed Device Action

Test using a safe method of making a test entity temporarily unavailable.

- [ ] Send an action to the unavailable entity.
- [ ] Jarvis distinguishes **command sent** from **state actually changed**.

---

# 24. Routing Acceptance Tests

These tests are specifically about selecting the correct architecture path.

## 24.1 Commands That Should Stay Local

The following should use Home Assistant/local intent handling when supported:

- [ ] **"Turn on living room light one."** → LOCAL
- [ ] **"Turn off living room light two."** → LOCAL
- [ ] **"Is living room light one on?"** → LOCAL
- [ ] **"Turn on the TV."** → LOCAL
- [ ] **"Turn off the TV."** → LOCAL
- [ ] **"Is the TV on?"** → LOCAL
- [ ] **"Pause."** → LOCAL → defaults to Kodi on `alan-tv`
- [ ] **"Resume."** → LOCAL → defaults to Kodi on `alan-tv`
- [ ] **"Mute."** → LOCAL → defaults to Kodi on `alan-tv`
- [ ] **"Set the volume to fifty percent."** → LOCAL → defaults to Kodi on `alan-tv`
- [ ] **"Wake alan-framework-laptop."** → LOCAL when HA exposes the WOL entity.

For every test above:

- [ ] Verify the request did **not** unnecessarily invoke OpenClaw/LLM reasoning.

## 24.2 Commands That Should Route to OpenClaw

The following should intentionally use OpenClaw:

- [ ] **"Play the movie The Incredibles from Jellyfin on Kodi."** → LLM
- [ ] **"Do I have the song Believer by Imagine Dragons in Navidrome?"** → LLM
- [ ] **"What is my progress in the book Harry Potter and the Sorcerer's Stone in Audiobookshelf?"** → LLM
- [ ] **"What events are on my calendar tomorrow?"** → LLM
- [ ] **"What is the email address for Jarvis Test Contact?"** → LLM
- [ ] **"Open Firefox on alan-framework-laptop."** → LLM
- [ ] **"Take a screenshot of alan-framework-laptop and describe what is on the screen."** → LLM
- [ ] **"List the files in my Filebrowser folder."** → LLM
- [ ] **"List my five newest emails in my fifefin.com mailbox."** → LLM
- [ ] **"Find the nearest Walmart to my home address."** → LLM
- [ ] **"Is Bitcoin Core on my node fully synchronized?"** → LLM

For every test above:

- [ ] Verify OpenClaw chose the correct tool/service rather than answering from unsupported model knowledge.

---

# 25. Regression Test Set

Once individual sections work, keep this small set as the **fast regression suite** after significant changes.

- [ ] **[LOCAL]** "Turn on living room light one."
- [ ] **[LOCAL]** "Is the TV on?"
- [ ] **[LOCAL]** "Pause." → Kodi on `alan-tv`
- [ ] **[LOCAL]** "Set the volume to fifty percent." → Kodi on `alan-tv`
- [ ] **[LLM]** "Play the movie The Incredibles from Jellyfin on Kodi."
- [ ] **[LLM]** "Do I have the song Believer by Imagine Dragons in Navidrome?"
- [ ] **[LLM]** "What is my progress in the book Harry Potter and the Sorcerer's Stone in Audiobookshelf?"
- [ ] **[LLM]** "What events are on my calendar tomorrow?"
- [ ] **[LLM]** "What is the email address for TEST_CONTACT?"
- [ ] **[LLM]** "List the open applications on alan-framework-laptop."
- [ ] **[LLM]** "List the files in my Filebrowser folder."
- [ ] **[LLM]** "List my five newest emails in my fifefin.com mailbox."
- [ ] **[LLM]** "Find the nearest Walmart to my home address."
- [ ] **[LLM]** "Is Bitcoin Core on my node fully synchronized?"

---

# 26. Backlog / Ideas to Add Later

Keep possible future capabilities here without mixing them into the active acceptance suite.

- [ ] Android phone agent / Siri-like phone control
- [ ] Nostr messaging interface
- [ ] Immich / photo search
- [ ] Chess.com / Lichess integration
- [ ] TV source switching
- [ ] Physical TV volume through CEC
- [ ] Additional smart-home devices

---
