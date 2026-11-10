# PeopleMaps privacy policy

Version 1, drafted 31 October 2026, for the app version that adds problem
reports. This is the plain-language version of what the app does with your
information. The engineering details are in `Docs/REPORTS.md`; if the two
ever disagree, the engineering document is the one being built from and this
one is wrong and gets fixed.

> **Draft, not published.** One thing to settle first (`Docs/REPORTS.md`): what
> Cloudflare's logs record, checked on the deployed server (4.6).

## The short version

- The app works offline. Maps, search and routes are on your phone.
- Nothing leaves your phone unless you tap **Send** on a report you have
  read, **Download King County** in Settings (see Downloading a bigger map), or
  **Send to PeopleMaps** on a trip log you chose to keep (see Sending a trip log).
- There are no accounts, no sign-in, no analytics, no ads, no tracking.
- A report you send is stored on our server and read by a maintainer. Nothing
  is published automatically. A maintainer may file a useful report as a public
  GitHub issue by hand. An issue never has your report ID, your exact start and
  destination or your GPS position, but it can show the route and where along it
  you flagged, which can place you to within metres.
- You can see, export and delete everything on the phone, and delete what you
  sent from our server (see Deleting for the limits). The app contacts the
  server only when you tap Send, Check status or Delete my reports, when it
  downloads map data for a region, or when you tap Send to PeopleMaps on a trip
  log. A region download sends only Apple's check
  that this is a genuine copy of the app and the name of the file it wants.
  For 90 days the server keeps that check's key ID and public key, whether the
  build was a development one, and the hour; they identify this install of the
  app, not you.

> **Alpha builds.** No server is deployed yet, so nothing below about sending to our server happens: a report is a
> `.json` file you share yourself from the share sheet (for example to iCloud Drive), after seeing what is in it. For reports the app
> contacts no server; a map download and Send to PeopleMaps on a trip log do (both below). See `Docs/REPORTS.md` section 11.

## What the app keeps on your phone

- Problem reports you start, until you swipe them away, and moments you mark during guidance.
- A usage log, only if you turn it on in Settings, under Trip logs, Usage log (off by default). One line per guided trip:
  the date and time, mode, extra-time limit, which route you started, both time estimates, whether a calmer route was
  offered, how many reroutes, where you left the route (rounded to about 100 m unless you turn on **Exact places**) and
  whether you arrived or ended early. The last 500 trips are kept. It stays on the phone unless you share the file from
  that page or tap **Send to PeopleMaps** there (see Sending a trip log), and **Clear usage log** deletes it from the phone.

- A detailed log, only if you turn on "Keep a detailed log" in Settings, under Trip logs, Detailed log (off by default, and
  separate from the usage log). It
  is for testing a build on your own phone. While you are guided on a walk, cycle or drive, it records the trip in a file on
  the phone: your start and destination (names and exact coordinates), both routes the app found with the app's time
  estimates, every location fix the phone gave the app (position, accuracy, speed, direction, about once a second), and what
  the app did (which turn you reached, leaving the route, rerouting, the lines the voice was given, muting, going to the
  background, the phone's temperature state and Low Power Mode). It also keeps, one file a day, what you searched for and
  which result you chose, the places you opened, the routes you previewed and the settings you changed. A trip shorter than
  3 minutes is deleted when it ends. It is not sent anywhere by itself: it stays on the phone, left out of backups, unless you share
  the files from that page or tap **Send to PeopleMaps** there (see Sending a trip log), and **Clear detailed log** deletes them from the phone. It keeps at most 500 MB and then removes the oldest
  trips and recordings. It does not
  record altitude.
- A manual recording, only if "Keep a detailed log" is on and you tap **Start recording** (the record button on the map,
  or the row in Settings under Trip logs, which is there only while the detailed log is on). It saves your location (position, accuracy, speed and direction, about once a second) in a file on the
  phone, with no route, until you tap **Stop**. It keeps going while PeopleMaps is in the background or the phone is
  locked, and iOS shows its blue location indicator for as long as it runs. It asks for the same "While Using the App"
  location permission as the rest of the app, never "Always", and cannot be started from the background. If the app is
  closed by the system, the recording ends and does not restart on its own. A recording shorter than 3 minutes is deleted
  when you stop it. Like the rest of the detailed log it stays on the phone, left out of backups, unless you share the
  files from the Detailed log page in Settings or tap **Send to PeopleMaps** there, and **Clear detailed log** deletes them from the phone.
- Recent app events, in memory only. The last 200 things the app did, or the last 10 minutes, whichever is fewer:
  that a route comparison started and how long it took, that guidance started or rerouted, that the map finished
  loading or moved the camera, how long a search took and how many results it found, and errors by type. Never a
  place, street, search text, note or position. It is never written to disk and is gone when the app quits or crashes.
  A report copies the list when you start it or mark a moment, so the file shows what the app was doing; you see it in
  "What's included" before you share. The app has no crash reports, so after a crash there is nothing to look at.
- Recent destinations and favourites.
- Your voice setting (muted or not).
- Flagged moments: snapshots you make during guidance by tapping **Flag this
  moment**. Each one holds the route you were on, where along it you were,
  the last few spoken instructions, your start and destination, and the
  app's state at that second. The exact start, destination and your GPS
  position at that moment are stored on the phone so you can choose later
  whether to send them. The phone keeps the last 50. They are left out of
  iCloud and computer backups, so they do not follow you to a new phone.

The app asks for your location once, the first time the home map shows.
While the app is open it uses your location to start routes and time
estimates from where you are, and, while guiding, to show where you are on
the map and say the next turn. It stops when the app leaves the screen, except
for a manual recording you started yourself (described above), which runs in the
background until you stop it and shows iOS's blue location indicator. We get
location information only inside a report you send, or a trip log you send. Every report shows the
corners near your start and destination and where along the route you flagged;
**Exact locations** adds the exact points and your GPS position.

## What leaves your phone, and only when you tap Send

Nothing is sent automatically. Flagging is silent and offline. Sending a
report needs a connection and happens only from the **Flagged moments**
list, after you have picked a category, optionally written one sentence, and
looked at every field. For reports, the app contacts our server at exactly three moments,
each one a button you tap: **Send**, **Check status** (which asks the server
which of your reports it still holds, and until when) and **Delete my
reports**. Opening the list, launching the app and guiding never contact it.

A report contains:

- **The route**: the streets it ran along, as map identifiers, and its length,
  time estimate and stress score as the app showed them. This is the route
  the app chose, which anyone with the app and the same start and end could
  see.
- **Your start and destination, snapped to the nearest street
  intersection.** An intersection is a public map feature, not your door.
  It can still be the corner nearest your home or work. Removing an endpoint
  before sending takes it out of the request but not out of the route, whose
  street list starts and ends at those corners. If the route's start or end
  worries you, do not send that report.
- **Exact start, destination and your GPS position when you flagged**, and the map
  ID of a named place you started from or went to, only if
  you turn on **Exact locations** for that report. It is off by default.
  Turn it on when a snapped report would not show the problem, for example
  when the trouble is the first turn out of a driveway.
- **Where along the route you were** when you flagged, in every report: a step
  number, a distance along it, and which half-kilometre square of Seattle that
  point is in. This is not a GPS reading, but together with the route's street list
  it places you to within metres of where you flagged, and a public issue
  includes all of it.
- **The last three spoken instructions** and how many seconds before the
  flag each was said. Where the voice said your destination's name, the
  report says "your destination" instead.
- **What the app was doing**: guiding, rerouting, paused or arrived; how
  many reroutes; whether the voice was muted; which quality of voice; miles
  or kilometres.
- **Your category** and **your sentence**, if you wrote one. A maintainer reads
  your sentence, and it can appear in a public issue (see below). Please do not
  put names, addresses or anything about other people in it.
- **The app version, the map data version, your iPhone model and iOS
  version**, so we can reproduce the route with the same data.
- **The hour** you flagged it, in UTC, rounded down. Not the minute.

A report never contains your name, email, phone number, Apple ID, contacts,
photos, other apps, your saved places, your trip history, your device name,
your language or time zone, or your IP address as stored data.

## Downloading a bigger map

The King County map is an optional download from Settings, under Map. Tapping **Download King County** sends requests to our
server for the map files, and nothing else. There is no account. A request carries the name of the file and a check that
the app is a genuine copy of PeopleMaps (Apple's App Attest), and nothing about you: not your location, your searches,
your routes or your report ID. Like any web server, ours and our host's network see the address your phone connects from
for the moment of the download; `Docs/REPORTS.md` says what the server keeps. The app then checks every file against a
checksum it already has before using it. Downloads go over Wi-Fi unless you tap **Use cellular**.

> **Server deployed separately.** The app calls the server only when you tap Download. If the server is not deployed yet,
> or your device cannot do App Attest (the Simulator, some devices), the download fails with a message and nothing else
> is sent. To prove the app is genuine, the app makes a new App Attest key on your iPhone for each proof and sends the
> server that key's ID and Apple's attestation of it. The server keeps the key ID, its public key and the hour for 90
> days, which identifies one install of the app and not you. The download pass it returns is kept in your iPhone's
> Keychain for 24 hours.

## Sending a trip log

The usage log and the detailed log are off unless you turn them on, and they stay on the phone unless you share them or
tap **Send to PeopleMaps** on the log's page in Settings. That button is the only thing that sends a log; nothing is sent
on a timer or in the background.

- **What goes.** The log's files exactly as they are on the phone, the same files Share hands over. The usage log is one
  line per trip, with places rounded to about 100 m unless **Exact places** is on. The detailed log has exact places: your
  starts and destinations, every location fix of each trip and recording, what you searched for and the places you opened.
  Before anything is sent the app says how many files and how large, and that they include exact places when they do. Files
  already sent are not sent again.
- **What goes with it.** A check that the app is a genuine copy of PeopleMaps (Apple's App Attest, as for a map download),
  and nothing else: no name, no account, no report ID, no device name. The server does not record which install sent a
  file. The files themselves can still identify you: a log of your trips shows where you start and end them.
- **Where it is kept.** On our server at Cloudflare, in private storage separate from the map files, for the maintainer to
  read. It is not published and never filed as an issue. It is not encrypted beyond the connection and Cloudflare's own
  storage, so people with access to the project's Cloudflare account or its deploy credentials can read it while it is
  there.
- **How long.** Up to 30 days. The maintainer usually copies a log off the server sooner, which deletes it there, and
  the daily cleanup deletes anything older than 30 days. A copy the maintainer took is kept on their computer, outside
  the project's repository, for as long as it is useful for fixing the app.
- **Deleting.** **Clear** on the log's page deletes the phone's copy only. The app cannot delete a log from the server,
  because the server does not know which install sent it; ask through the project's GitHub issues (without personal
  details), or wait for the 30 days.

If your device cannot do App Attest (the Simulator, some devices), the button says the device can't send logs and
nothing is sent.

## Your report ID

The first time you send a report, the app asks our server for a random ID
and a secret key for it. The ID links your reports together so you can delete
them. It is not tied to you, your Apple ID or your phone, and it is not
backed up or restored to another phone. In **Flagged moments** you can see it,
or delete it with all your reports. There is no separate way to change it: after
**Delete my reports**, or if our server no longer recognises it, your next
report gets a new ID.

With the ID, our server keeps a scrambled copy of the key, your app version and
build, and the hours it was created and last contacted. Once it has no reports
left, this record is deleted a year after the last contact, or at once with
**Delete my reports**.

## Where a report goes

1. **Our server**, run by the people who make PeopleMaps: a Cloudflare Worker,
   which isn't tied to one country and runs at whichever Cloudflare location is
   nearest you, and a database kept in the United States. It stores the report
   for 90 days. Exact
   locations are kept apart from the rest, and only people with access to the
   project's Cloudflare account or to its deploy credentials (the automated deploy
   token can edit the database) can read them. The daily cleanup deletes
   the report within about a day after its 90 days, and Cloudflare can still
   restore it for 7 more days (see Deleting).
2. **A public GitHub issue**, only if a maintainer reads your report, finds it
   useful and files one by hand at `github.com/electropicks/peoplemaps`. The
   server never does this. An issue contains your report except for your exact
   start and destination, your GPS position and your report ID, with your start
   and destination shown only as half-kilometre squares. It can include your
   sentence, the route's street list and where along it you flagged; the
   maintainer may edit your sentence or leave out any of these. So someone with
   map data can still find the snapped corners where the route begins and ends,
   and where you were when you flagged, to within metres. Issues are public to
   anyone on the internet, and GitHub emails them to people who watch the
   project.

We never store or log IP addresses; Cloudflare necessarily sees them to
deliver traffic. The server does not log requests or their headers, has
Cloudflare's per-request logging turned off, and sets no cookies. Cloudflare
still keeps aggregate request statistics for the server (counts, status codes
and country). When you send
a report or get a report ID, the server reads your IP address only to hand it,
or for the newer IPv6 kind only its first half, to Cloudflare's rate limiter, so
that one source cannot flood the server. Those counts live in Cloudflare's memory for
about a minute. We store nothing from them.

## Deleting

- **On the phone**: swipe a flagged moment away, or delete them all. This
  does not contact the server.
- **On the server**: **Delete my reports** shows how many sent reports this
  phone remembers under your current report ID, asks you to confirm, then
  removes every report under that ID and the ID itself. It reaches only
  reports sent under your current ID (see below). The server can hold more than
  the number shown: the phone keeps only its last 50 moments, a moment you swiped away is no longer counted,
  and a send that was interrupted may have reached the server even though the
  phone doesn't show it as sent. If you edit such a report before sending again,
  the first copy stays on the server; only **Delete my reports** removes it.
- **If the server doesn't recognise your ID**: the app tells you so, and that it
  can't confirm whether your reports were deleted. This can happen if an earlier
  delete worked but the phone never heard back, or if the key on the phone is
  damaged. Anything left expires within its 90 days. Your next report gets a
  new ID.
- **Reports sent under an earlier ID**: if the key on the phone is damaged, your
  next report gets a new ID, and **Delete my reports** reaches only the new one.
  Reports sent under the earlier ID can't be deleted from the app. They stay on
  the server until they expire, within 90 days of sending. The app remembers that
  an earlier ID may hold reports even after you remove them from the list or the
  list drops them, and then it doesn't say that all your reports were deleted: it
  says which ones it deleted and that it could not reach the others.
- **If you lose the phone**: the ID's key lives only on that phone, so without
  it, or if its Keychain is erased, your reports cannot be deleted from the app
  and stay until their 90 days end.
- **A public issue**: deleting does not reach an issue a maintainer has already
  filed. It carries no report ID, so it cannot be matched to you automatically.
  You can ask us to remove one through the project's GitHub issues. Removing an
  issue is not erasing it: public archives of GitHub activity record an issue
  when it is opened, GitHub has already emailed it to people watching the
  project, and search engines may hold a copy. Neither we nor GitHub can recall
  those. This is why nothing is published without a maintainer reading it first.
- **The restore copy**: Cloudflare keeps a restorable copy of our database
  from the last 7 days that only we, the maintainers, can use to undo a
  mistake. We cannot shorten it or turn it off. It is not reachable from the
  app or the server. So a deleted report is completely gone from Cloudflare
  7 days after you delete it, and a report that expired is gone about 8 days after
  its 90 days. If we move to Cloudflare's paid plan the window becomes 30
  days, and if we move to another host it changes again; either way this
  policy changes first, with a new version number.

## What we do not do

- No analytics or crash-reporting services, no advertising, no third-party
  SDKs that phone home.
- No tracking across apps or sites, no advertising identifier, no
  fingerprinting of your device.
- No Apple Maps data in the app. "Look up in Apple Maps" hands you to the
  Apple Maps app and shows nothing from it inside PeopleMaps.
- No selling, sharing or renting of anything. There is nothing to sell.

## Honesty about routes

Route times are estimates. There is no live traffic, closures or signal
timing. A calmer route is one the app's stress model scores lower, not a
safety rating; the app never says a route is safe, and neither does this
policy. Where the map's tags are missing, the app says the thing is unknown.

## Changes and contact

This policy changes only with a new app version, and the version number at
the top changes with it. The current text is always in the app's repository
at `Docs/PRIVACY.md`. Questions and requests go to the project's GitHub
issues at `github.com/electropicks/peoplemaps/issues`, which are public, so
do not include personal details there either.
