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

- [x] **[LOCAL / Home Assistant]** Say exactly: **"What is [currently] playing?"**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Pause/Stop."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Unpause/Resume."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Skip."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn on/off subtitles."**

## 3.2 Kodi Volume

- [x] **[LOCAL / Home Assistant]** Say exactly: **"Mute/unmute."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn the volume up/down."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Set the volume to fifty percent."**

Expected target for every command above when no target is named: **Kodi on `alan-tv`**.

---

# 4. Jellyfin

Primary playback for now is through the **Jellyfin Kodi add-on**. A Home Assistant Jellyfin integration is not required.

OpenClaw queries Jellyfin directly for its library and activity, then asks Kodi to play the matching item from its synchronized Jellyfin library.

### Kodi setup required

The Jellyfin for Kodi add-on keeps its authentication, playback mode, library selections, and synchronization state in Kodi rather than in Home Assistant:

- Sign in to the Jellyfin server from the Jellyfin add-on.
- Select **Add-on mode**.
- Select and synchronize the Jellyfin movie and TV libraries that Kodi should expose.

No Home Assistant Jellyfin integration, entity, automation, or custom Assist intent is needed for these OpenClaw requests.

## 4.1 Jellyfin Library Queries

- [x] **[LLM / OpenClaw]** Say exactly: **"Do I have the movie The Incredibles in Jellyfin?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"Do I have the TV show Psych in Jellyfin?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"List my Jellyfin movies named Harry Potter."**
- [x] **[LLM / OpenClaw]** Say exactly: **"List the episodes of season one of Psych in Jellyfin."**

## 4.2 Jellyfin Playback Through Kodi

The request explicitly states the media type to reduce ambiguity.

- [x] **[LLM / OpenClaw]** Say exactly: **"Play the movie The Incredibles from Jellyfin on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play the TV show Psych season one episode three from Jellyfin on Kodi."**
- [ ] **[LLM / OpenClaw]** Using the title of a video in the library, say: **"Play the video 15 Minute Beginner Stretch Flexibility Routine from Jellyfin on Kodi."**

Expected behavior:

1. If the TV needs to be on, turn it on.
2. If Kodi needs to be opened, open Kodi.
3. Use Kodi as the playback target.
4. Use the Jellyfin Kodi add-on/library path as needed.
5. Verify that playback actually begins.

## 4.3 Jellyfin Activity Outside Kodi

This queries Jellyfin directly, so it includes active clients other than Kodi.

- [x] **[LLM / OpenClaw]** Say exactly: **"What is currently playing on Jellyfin?"**

---

# 5. Navidrome

Playback uses the declaratively configured Navidrome Kodi add-on.

OpenClaw should also be able to inspect the Navidrome library independently from Kodi.

## 5.1 Navidrome Library Queries

- [x] **[LLM / OpenClaw]** Say exactly: **"Do I have the song Believer by Imagine Dragons in Navidrome?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"List my songs by Imagine Dragons in Navidrome."**
- [x] **[LLM / OpenClaw]** Say exactly: **"List my albums by Imagine Dragons in Navidrome."**

## 5.2 Navidrome Playback Through Kodi

- [x] **[LLM / OpenClaw]** Say exactly: **"Play the song Believer by Imagine Dragons from Navidrome on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play the album Evolve by Imagine Dragons from Navidrome on Kodi."**

Expected behavior:

1. If the TV needs to be on, turn it on and allow time for its state to update.
2. If Kodi needs to be opened, open Kodi.
3. Resolve the song or album directly in Navidrome.
4. Play it through the Navidrome Kodi add-on.
5. Verify that audio playback actually begins.

## 5.3 Navidrome Activity Outside Kodi

This queries Navidrome directly and includes compatible clients that report
what they are currently playing, not only Kodi.

- [x] **[LLM / OpenClaw]** Say exactly: **"What is currently playing on Navidrome?"**

---

# 6. Audiobookshelf

Playback uses the declaratively configured Audiobookshelf Kodi add-on and
resumes the progress stored by Audiobookshelf.

OpenClaw should also connect directly to Audiobookshelf for library and progress information.

## 6.1 Audiobookshelf Library

- [x] **[LLM / OpenClaw]** Say exactly: **"Do I have the book Harry Potter and the Sorcerer's Stone in Audiobookshelf?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"List my books in Audiobookshelf."**
- [x] **[LLM / OpenClaw]** Say exactly: **"What Audiobookshelf books am I currently in progress on?"**

## 6.2 Audiobook Details and Progress

- [x] **[LLM / OpenClaw]** Say exactly: **"How long is The Hobbit in Audiobookshelf?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"What is my progress in the book Harry Potter and the Sorcerer's Stone in Audiobookshelf?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"How much time is left in the book Harry Potter and the Sorcerer's Stone in Audiobookshelf?"**

## 6.3 Audiobookshelf Playback Through Kodi

- [x] **[LLM / OpenClaw]** Say exactly: **"Play the book Harry Potter and the Sorcerer's Stone from Audiobookshelf on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Resume the book Harry Potter and the Sorcerer's Stone from Audiobookshelf on Kodi."**

Expected behavior:

1. If the TV needs to be on, turn it on and allow time for its state to update.
2. If Kodi needs to be opened, open Kodi.
3. Resolve the book directly in Audiobookshelf.
4. Resume its saved Audiobookshelf progress through the Kodi add-on.
5. Verify that audio playback begins at the saved position.

---

# 7. Invidious

OpenClaw resolves YouTube titles and channels through Invidious, then plays the result through the Invidious Kodi add-on. The add-on and its account settings are managed declaratively on `alan-tv`.

## 7.1 Video by Title

- [x] **[LLM / OpenClaw]** Say exactly: **"Play the YouTube video Google Pixel 11/Pro Review: Poker Face on Kodi."**

Expected behavior: resolve an unambiguous video title through Invidious, open it in Kodi, and verify that playback begins.

## 7.2 Latest Video From a Channel

- [x] **[LLM / OpenClaw]** Say exactly: **"Play the latest YouTube video from the GothamChess channel on Kodi."**

Expected behavior: resolve the channel through Invidious, select its newest listed video, open it in Kodi, and verify that playback begins.

---

# 8. Live TV Through Kodi

OpenClaw tunes live TV through Kodi's configured PVR channels. Channel numbers
are authoritative. Only the four major-network stations below support name
aliases; use a channel number for every other station.

## 8.1 Channel Number

- [x] **[LLM / OpenClaw]** Say exactly: **"Play channel 8.1 on Kodi."**

## 8.2 Network Aliases

- [x] **[LLM / OpenClaw]** Say exactly: **"Play ABC on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play NBC on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play CBS on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play FOX on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play WFAA on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play KXAS on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play KTVT on Kodi."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play KDFW on Kodi."**

Expected behavior:

1. If the TV needs to be on, turn it on and allow time for its state to update.
2. If Kodi needs to be opened, open Kodi.
3. For a network alias, use its explicitly configured channel number.
4. Tune the matching Kodi PVR channel.
5. Verify that live-TV playback actually begins.

---

# 9. Video Games on alan-tv

Game requests use `alan-tv`. Home Assistant opens or closes an emulator or
launcher by itself. Named-game requests use OpenClaw, which starts the required
emulator or launcher with the selected game without pre-opening its Home
Assistant switch. Switch games use Ryubing rather than Eden. Heroic inventory
includes locally installed Epic, GOG, and Amazon games.

### Home Assistant setup required

In Home Assistant, assign the Azahar, Dolphin, Eden, Heroic, melonDS,
RetroArch, Ryubing, and Steam switches to **Living Room** and expose them to
Assist. Add voice aliases there only when speech recognition needs one.

## 9.1 Emulator and Launcher Power

- [x] **[LOCAL / Home Assistant]** Say exactly: **"Turn Dolphin on/off."**
- [x] **[LOCAL / Home Assistant]** Say exactly: **"Is Dolphin on/off?"**
- [x] **[LOCAL / Home Assistant]** Repeat both tests for **RetroArch**,
  **Eden**, **Ryubing**, **Azahar**, **melonDS**, **Steam**, and **Heroic**.

Expected behavior: each switch reports the real application state. Turning an
emulator or launcher off also closes a game currently running through it.

## 9.2 Find and Launch Games

- [x] **[LLM / OpenClaw]** Say exactly: **"What games do I have on alan-tv?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play/close Super Mario 64 on alan-tv."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play/close Mario Kart Wii on alan-tv."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play/close New Super Mario Bros. on alan-tv."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play/close Mario Kart 7 on alan-tv."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Play/close Super Mario Odyssey on alan-tv."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Play/close Hogwarts Legacy on alan-tv."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Play/close Rocket League on alan-tv."**

Expected behavior:

1. Turn on the physical TV if needed and allow time for its state to update.
2. Resolve the spoken title against the installed games on `alan-tv`.
3. Refuse an ambiguous match instead of choosing arbitrarily.
4. Launch or close the resolved game directly without first powering its
   emulator or launcher through Home Assistant.
5. Verify that the expected game or emulator window appears fullscreen.

## 9.3 Missing and Ambiguous Games

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play Mario on alan-tv."**
- [ ] Verify that Jarvis asks which matching Mario game to use.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Play Jarvis Definitely Missing Game 987654 on alan-tv."**
- [ ] Verify that Jarvis reports no match and launches nothing.

---

# 10. Calendar / Radicale

## 10.1 Read Calendar

OpenClaw reads the synchronized Radicale calendar using bounded local-time
ranges. Recurring events are expanded for the requested range.

- [x] **[LLM / OpenClaw]** Say exactly: **"What events are on my calendar today?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"What events are on my calendar tomorrow?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"What events are on my calendar this week?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"What is my next calendar event?"**

## 10.2 Check Availability

Availability is calculated from events that overlap the requested instant or
time window, including all-day and recurring events.

- [x] **[LLM / OpenClaw]** Say exactly: **"Am I free this Friday at three PM?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"Find a one-hour free period on my calendar tomorrow afternoon."**

## 10.3 Create Calendar Events

Use a disposable test event when testing CRUD.

- [x] **[LLM / OpenClaw]** Say exactly: **"Create a calendar event named Jarvis Test Event tomorrow at three PM for one hour."**

## 10.4 Update Calendar Events

- [x] **[LLM / OpenClaw]** Say exactly: **"Move the calendar event Jarvis Test Event tomorrow from three PM to four PM."**

## 10.5 Delete Calendar Events

- [x] **[LLM / OpenClaw]** Say exactly: **"Delete the calendar event Jarvis Test Event tomorrow at four PM."**

---

# 11. Contacts / Radicale

Use a disposable contact and run these sections in order. OpenClaw resolves an
exact contact before reading or changing it and refuses ambiguous mutations.

## 11.1 Create Contact

- [x] **[LLM / OpenClaw]** Say exactly: **"Create a contact named Jarvis Test Contact with phone number 214-555-0100 and email address jarvis-test@example.com."**

## 11.2 Read Contacts

- [x] **[LLM / OpenClaw]** Say exactly: **"Find the contact named Jarvis Test Contact."**
- [x] **[LLM / OpenClaw]** Say exactly: **"What is the phone number for Jarvis Test Contact?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"What is the email address for Jarvis Test Contact?"**

## 11.3 Update Contact

- [x] **[LLM / OpenClaw]** Say exactly: **"Change the phone number for Jarvis Test Contact to 214-555-0101."**

## 11.4 Delete Contact

- [x] **[LLM / OpenClaw]** Say exactly: **"Delete the contact named Jarvis Test Contact."**

---

# 12. Computer Control

For computer-control commands, the preferred behavior is:

- Require the user to explicitly name the computer for status, application,
  clipboard, filesystem, and other computer-specific operations.
- Screen interaction and requests to describe the current screen are the only
  exception. If no computer is named for those requests, use `alan-tv`.
- An explicitly named computer always overrides the screen default.

## 12.1 Online / Status

- [x] **[LLM / OpenClaw]** Say exactly: **"Is alan-framework-laptop online?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"Is alan-tv online?"**

The answer should distinguish an offline host from an online host whose desktop
session is not currently available.

## 12.2 List Apps / Windows

- [x] **[LLM / OpenClaw]** Say exactly: **"List the open applications on alan-framework-laptop."**
- [x] **[LLM / OpenClaw]** Say exactly: **"List the open applications on alan-tv."**

These should list applications with open windows, not every installed app.

## 12.3 Open Applications

- [x] **[LLM / OpenClaw]** Say exactly: **"Open Firefox on alan-framework-laptop."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Open Kodi on alan-tv."**

## 12.4 Close Applications

- [x] **[LLM / OpenClaw]** Say exactly: **"Close Firefox on alan-framework-laptop."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Close Kodi on alan-tv."**

## 12.5 Screen Inspection

- [ ] **[LLM / OpenClaw]** Say exactly: **"Take a screenshot of alan-framework-laptop and describe what is on the screen."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Take a screenshot and describe what is on the screen."** → defaults to `alan-tv`

## 12.6 Clipboard

- [x] **[LLM / OpenClaw]** Say exactly: **"Set the clipboard on alan-framework-laptop to Jarvis clipboard test."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Read the clipboard on alan-framework-laptop."**
---

# 13. Browser Control

## 13.1 Open / Read Pages

- [x] **[LLM / OpenClaw]** Say exactly: **"Open example.com in the browser and tell me the page title."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Open the NixOS website in the browser and summarize the home page."**

## 13.2 Search

- [x] **[LLM / OpenClaw]** Say exactly: **"Use the managed browser and searxng.fifefin.com to search for the NixOS Home Manager manual and tell me the title of the official result."**

Expected result: **"Preface - Home Manager Manual - Nix community projects."**

## 13.3 Page Interaction

Use a harmless page specifically chosen for testing before adding site-specific workflows.

- [x] **[LLM / OpenClaw]** Say exactly: **"Open example.com in the managed browser, click the Learn more link, and tell me the title and URL of the resulting page."**
- [x] Verify that OpenClaw used a browser snapshot to identify and click the link, then inspected the resulting page.
- [x] **[LLM / OpenClaw]** Say exactly: **"Open https://httpbin.org/forms/post in the managed browser, enter Jarvis Test as the customer name, enter Browser form test as the delivery instructions, submit the form, and tell me the submitted values."**
- [x] Verify that the returned page reports `Jarvis Test` for `custname` and `Browser form test` for `comments`.

These tests use public pages that do not require authentication or retain the submitted test data as an account change.

---

# 14. File Access

OpenClaw should have **unrestricted filesystem access** on machines where its tool is intentionally installed/configured.

It should also have especially convenient access to the Filebrowser/Syncthing folder because that is a common working area.

## 14.1 General Filesystem

- [x] **[LLM / OpenClaw]** Say exactly: **"List the files in slash tmp on alan-framework-laptop."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Create a file named slash tmp slash jarvis-test.txt on alan-framework-laptop containing the text Jarvis file test."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Read slash tmp slash jarvis-test.txt on alan-framework-laptop."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Change slash tmp slash jarvis-test.txt on alan-framework-laptop so it contains the text Jarvis file test updated."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Delete slash tmp slash jarvis-test.txt on alan-framework-laptop."**

## 14.2 Filebrowser / Syncthing Folder

These commands use OpenClaw's dedicated personal-files tool. Do not name a
computer; OpenClaw operates on its local replica and Syncthing propagates the
changes to the other replicas.

- [x] **[LLM / OpenClaw]** Say exactly: **"List the files in my Filebrowser folder."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Create a file named Jarvis Test.txt in my Filebrowser folder containing the text Filebrowser integration works."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Tell me what is in the file named Jarvis Test.txt in my Filebrowser folder."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Append the text OpenClaw edited this file to Jarvis Test.txt in my Filebrowser folder."**
- [x] **[LLM / OpenClaw]** Say exactly: **"Delete Jarvis Test.txt from my Filebrowser folder."**

---

# 15. Self-Hosted Email — fifefin.com

All email tests should use the self-hosted `fifefin.com` mail system unless this document is changed later.

Use a test mailbox/contact you control for send/reply tests.

## 15.1 Read / Search Email

- [ ] **[LLM / OpenClaw]** Say exactly: **"List my five newest emails in my fifefin.com mailbox."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"List my unread emails in my fifefin.com mailbox."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Find emails in my fifefin.com mailbox with Jarvis Test in the subject."**

## 15.2 Draft Email

- [ ] **[LLM / OpenClaw]** Say exactly: **"Draft an email from my fifefin.com account to TEST_EMAIL with subject Jarvis Test and body This is a Jarvis email test. Do not send it."**
- [ ] Confirm a draft exists and has the exact intended recipient, subject, and body.

## 15.3 Send Email

- [ ] **[LLM / OpenClaw]** Say exactly: **"Send an email from my fifefin.com account to TEST_EMAIL with subject Jarvis Send Test and body This is a Jarvis send test."**
- [ ] Confirm receipt at the test mailbox.

## 15.4 Reply

- [ ] Send a test message to the fifefin.com account with subject `Jarvis Reply Test`.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Reply to the newest email with subject Jarvis Reply Test and say This is the Jarvis reply."**
- [ ] Confirm the reply remains in the original email thread.

## 15.5 Mail Management

- [ ] **[LLM / OpenClaw]** Say exactly: **"Mark the newest email with subject Jarvis Test as read."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Archive the newest email with subject Jarvis Test."**

---

# 16. XMPP / Prosody

## 16.1 Send Message

- [ ] **[LLM / OpenClaw]** Say exactly: **"Send the XMPP account TEST_XMPP the message This is a Jarvis XMPP test."**
- [ ] Confirm the message arrives.

## 16.2 Read Messages

- [ ] Send a test message to the user's XMPP account.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Read my newest XMPP message."**

## 16.3 Reply

- [ ] **[LLM / OpenClaw]** Say exactly: **"Reply to my newest XMPP message and say This is the Jarvis XMPP reply."**

## 16.4 Talk to Jarvis Through XMPP

- [ ] Send Jarvis an XMPP message containing exactly: **"Is the TV on?"**
- [ ] Jarvis receives and processes the message.
- [ ] It uses the same Home Assistant/OpenClaw tool stack as another Jarvis interface.
- [ ] The answer is sent back through XMPP.

---

# 17. Maps / Places / Location Awareness

OpenClaw should know the user's configured home address/location without requiring the address to be repeated on every request.

Store the home address in an appropriate private configuration/secret source rather than hard-coding it into this public repo if the repository is public.

- [ ] Home address/location is available to OpenClaw through configuration.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Find the nearest Walmart to my home address."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"How far is the nearest Walmart from my home address?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Find three restaurants within five miles of my home address."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"What is the address of the nearest Home Depot to my home address?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is the nearest Walmart to my home address open right now?"**

---

# 18. Bitcoin / Node Status

Keep Bitcoin functionality read-only unless explicitly expanded later.

- [x] **[LLM / OpenClaw]** Say exactly: **"What is the current Bitcoin block height on my node?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"Is Bitcoin Core on my node fully synchronized?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"Is Fulcrum, my Electrum server, running and fully synchronized?"**

Balance and transaction history require a loaded read-only Bitcoin Core wallet
on `alan-node`. Import only watch-only descriptors or public keys; never expose
wallet private keys to OpenClaw.

- [x] A watch-only wallet is loaded on `alan-node` and appears in `bitcoin-read wallets`.
- [x] **[LLM / OpenClaw]** Say exactly: **"What is my Bitcoin balance?"**
- [x] **[LLM / OpenClaw]** Say exactly: **"What are my five latest Bitcoin transactions?"**
---

# 19. System / Service Status

OpenClaw should be able to inspect known hosts and services.

- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Jellyfin running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Navidrome running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Audiobookshelf running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is Home Assistant running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is my Prosody XMPP server running?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Which of my configured computers are offline?"**

## 19.1 Service Logs / Diagnosis

- [ ] **[LLM / OpenClaw]** Say exactly: **"Show me the recent errors from the Jellyfin service."**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Tell me why the Navidrome service is not running."**

Run failure-path tests against a disposable/test service where possible instead of deliberately breaking production services.

---

# 20. AdGuard Home

Use Home Assistant directly for capabilities that its AdGuard integration already exposes cleanly. Use OpenClaw only for queries/actions that require deeper inspection outside HA.

- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Is AdGuard Home enabled?"**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn off AdGuard Home filtering."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn on AdGuard Home filtering."**

If detailed statistics are not available as HA intents, route them through OpenClaw:

- [ ] **[LLM / OpenClaw]** Say exactly: **"How many DNS requests has AdGuard Home blocked today?"**
- [ ] **[LLM / OpenClaw]** Say exactly: **"Is raw.githubusercontent.com currently being blocked by AdGuard Home?"**

---

# 21. Wake-on-LAN / Automatic Computer Wake

Jarvis should be able to wake any explicitly named configured computer.

- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Wake alan-framework-laptop."**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"Turn on alan-framework-laptop."**

If Home Assistant does not expose a given computer's WOL switch cleanly, that specific host may instead use OpenClaw; prefer Home Assistant when possible.

## 21.1 Automatic Wake as Part of Another Task

When a requested task requires a computer that is currently off, Jarvis should wake it first and then continue the original task.

- [ ] Turn off a test computer that supports WOL.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Open Firefox on alan-framework-laptop."**
- [ ] Jarvis detects that `alan-framework-laptop` is offline.
- [ ] Jarvis sends the configured Wake-on-LAN action.
- [ ] Jarvis waits/checks until the computer is reachable.
- [ ] Jarvis opens Firefox after the machine becomes available.

---

# 22. Weather / Time

Prefer Home Assistant/local integrations for simple deterministic weather/time queries when those intents are available.

- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What is the weather at home?"**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What is the weather forecast at home tomorrow?"**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What time is it in London?"**
- [ ] **[LOCAL / Home Assistant]** Say exactly: **"What is today's date?"**

---

# 23. Cross-Tool Workflows

Do these only after the underlying individual tools pass.

## 23.1 Contact → Email

- [ ] **[LLM / OpenClaw]** Say exactly: **"Find TEST_CONTACT in my contacts and send that contact an email from my fifefin.com account with subject Jarvis Cross Tool Test and body This is a cross-tool test."**

Expected chain:

Contacts → resolve email address → fifefin.com mail → send → report actual send result.

## 23.2 Email → Calendar

Create a test email containing an explicit date/time first.

- [ ] **[LLM / OpenClaw]** Say exactly: **"Read the newest email with subject Jarvis Meeting Test and create the meeting described in that email on my calendar."**

Expected chain:

Email → extract event → calendar → create event → verify.

## 23.3 Media + Automatic Wake

With the media PC powered off:

- [x] **[LLM / OpenClaw]** Say exactly: **"Play the movie The Incredibles from Jellyfin on Kodi."**

Expected chain:

Detect media PC offline → wake media PC → wait for Kodi/tool availability → locate Jellyfin movie → start playback → verify playback.

---

# 24. Failure / Truthfulness Tests

These tests ensure Jarvis does not claim success merely because it attempted an action.

## 24.1 Offline Computer

- [ ] Choose a computer that is intentionally offline and cannot currently be woken.
- [ ] **[LLM / OpenClaw]** Say exactly: **"Open Firefox on OFFLINE_TEST_COMPUTER."**
- [ ] Jarvis reports that the computer is unavailable instead of claiming Firefox opened.

## 24.2 Missing Media

- [ ] **[LLM / OpenClaw]** Say exactly: **"Play the movie Jarvis Definitely Missing Movie 987654 from Jellyfin on Kodi."**
- [ ] Jarvis reports that the movie could not be found.
- [ ] Jarvis does not claim playback started.

## 24.3 Missing Contact

- [ ] **[LLM / OpenClaw]** Say exactly: **"Find the phone number for Jarvis Definitely Missing Contact 987654."**
- [ ] Jarvis reports no matching contact.

## 24.4 Failed Device Action

Test using a safe method of making a test entity temporarily unavailable.

- [ ] Send an action to the unavailable entity.
- [ ] Jarvis distinguishes **command sent** from **state actually changed**.

---

# 25. Routing Acceptance Tests

These tests are specifically about selecting the correct architecture path.

## 25.1 Commands That Should Stay Local

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

## 25.2 Commands That Should Route to OpenClaw

The following should intentionally use OpenClaw:

- [ ] **"Play the movie The Incredibles from Jellyfin on Kodi."** → LLM
- [ ] **"Do I have the song Believer by Imagine Dragons in Navidrome?"** → LLM
- [ ] **"What is my progress in the book Harry Potter and the Sorcerer's Stone in Audiobookshelf?"** → LLM
- [ ] **"What events are on my calendar tomorrow?"** → LLM
- [ ] **"What is the email address for Jarvis Test Contact?"** → LLM
- [ ] **"Open Firefox on alan-framework-laptop."** → LLM
- [ ] **"Take a screenshot of alan-framework-laptop and describe what is on the screen."** → LLM
- [ ] **"Play Super Mario 64 on alan-tv."** → LLM
- [ ] **"List the files in my Filebrowser folder."** → LLM
- [ ] **"List my five newest emails in my fifefin.com mailbox."** → LLM
- [ ] **"Find the nearest Walmart to my home address."** → LLM
- [ ] **"Is Bitcoin Core on my node fully synchronized?"** → LLM

For every test above:

- [ ] Verify OpenClaw chose the correct tool/service rather than answering from unsupported model knowledge.

---

# 26. Regression Test Set

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
- [ ] **[LLM]** "Play Super Mario 64 on alan-tv."
- [ ] **[LLM]** "List the files in my Filebrowser folder."
- [ ] **[LLM]** "List my five newest emails in my fifefin.com mailbox."
- [ ] **[LLM]** "Find the nearest Walmart to my home address."
- [ ] **[LLM]** "Is Bitcoin Core on my node fully synchronized?"

---

# 27. Backlog / Ideas to Add Later

Keep possible future capabilities here without mixing them into the active acceptance suite.

- [ ] Navigate Kodi
- [ ] Android phone agent / Siri-like phone control
- [ ] Nostr messaging interface
- [ ] Immich / photo search
- [ ] Chess.com / Lichess integration
- [ ] TV source switching
- [ ] Physical TV volume through CEC
- [ ] Lightning node status and read-only Lightning balances/transactions after a Lightning node is deployed
- [ ] Additional smart-home devices

---
