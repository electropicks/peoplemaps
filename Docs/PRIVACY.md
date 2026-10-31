# PeopleMaps privacy policy

Version 1, drafted 31 October 2026, for the app version that adds problem
reports. This is the plain-language version of what the app does with your
information. The engineering details are in `Docs/REPORTS.md`; if the two
ever disagree, the engineering document is the one being built from and this
one is wrong and gets fixed.

## The short version

- The app works offline. Maps, search and routes are on your phone.
- Nothing leaves your phone unless you tap **Send** on a report you have
  read.
- There are no accounts, no sign-in, no analytics, no ads, no tracking.
- A report becomes a public issue on GitHub, minus your exact locations.
- You can see, export and delete everything, on the phone and on our server.

## What the app keeps on your phone

- Recent destinations and favourites.
- Your voice setting (muted or not).
- Flagged moments: snapshots you make during guidance by tapping **Flag this
  moment**. Each one holds the route you were on, where along it you were,
  the last few spoken instructions, your start and destination, and the
  app's state at that second. The exact start, destination and your GPS
  position at that moment are stored on the phone so you can choose later
  whether to send them. The phone keeps the last 50. They are left out of
  iCloud and computer backups, so they do not follow you to a new phone.

Location is used while guiding to show where you are and say the next turn.
The app asks for it once, when you start a route, and uses it only while the
app is on screen. It is not collected by us unless you send a report with
exact locations on.

## What leaves your phone, and only when you tap Send

Nothing is sent automatically. Flagging is silent and offline. Sending a
report needs a connection and happens only from the **Flagged moments**
list, after you have picked a category, optionally written one sentence, and
looked at every field.

A report contains:

- **The route**: the streets it ran along, as map identifiers, and its length,
  time estimate and stress score as the app showed them. This is the route
  the app chose, which anyone with the app and the same start and end could
  see.
- **Your start and destination, snapped to the nearest street
  intersection.** An intersection is a public map feature, not your door.
  It can still be the corner nearest your home or work, so if that worries
  you, remove either endpoint before sending; the report is still useful.
- **Exact start, destination and your position when you flagged**, only if
  you turn on **Exact locations** for that report. It is off by default.
  Turn it on when a snapped report would not show the problem, for example
  when the trouble is the first turn out of a driveway.
- **Where along the route you were** when you flagged, as a step number and
  a distance, not as a coordinate.
- **The last three spoken instructions** and how many seconds before the
  flag each was said.
- **What the app was doing**: guiding, rerouting, paused or arrived; how
  many reroutes; whether the voice was muted; which quality of voice; miles
  or kilometres.
- **Your category** and **your sentence**, if you wrote one. The sentence is
  published as you wrote it. Please do not put names, addresses or anything
  about other people in it.
- **The app version, the map data version, your iPhone model and iOS
  version**, so we can reproduce the route with the same data.
- **The hour** you flagged it, in UTC, rounded down. Not the minute.

A report never contains your name, email, phone number, Apple ID, contacts,
photos, other apps, your saved places, your trip history, your device name,
your language or time zone, or your IP address as stored data.

## Your report ID

The first time you send a report, the app asks our server for a random ID
and a secret key for it. The ID links your reports together so you can delete
them. It is not tied to you, your Apple ID or your phone, and it is not
backed up or restored to another phone. In **Flagged moments** you can see
it, get a new one (older reports stay under the old one until you delete
them) or delete it with all your reports.

## Where a report goes

1. **Our server**, a Cloudflare Worker and database in the United States,
   run by the people who make PeopleMaps. It stores the report for 90 days,
   with exact locations kept apart from the rest and shown only to project
   maintainers who ask for them by issue number with their own GitHub login.
   After 90 days the report is deleted. What remains is a count: how many
   reports of each category, for each travel mode, in each square of about
   half a kilometre, per week. Counts say nothing about a person and are
   kept.
2. **A public GitHub issue** at `github.com/electropicks/peoplemaps`. The
   server files it for you. It contains everything in the report except
   exact locations and your report ID. Issues are public to anyone on the
   internet. A later automated step may replay the route from the issue and
   propose a fix.

The server does not store IP addresses, does not log requests, and sets no
cookies. Cloudflare, as the host, sees your connection the way any website's
host does in order to deliver it; we do not receive that.

## Deleting

- **On the phone**: swipe a flagged moment away, or delete them all. This
  does not contact the server.
- **On the server**: **Delete my reports** removes every report under your
  ID and the ID itself. The public issues are edited to say "Report withdrawn
  by its sender" with only the category and data version left, and are
  closed. Comments other people wrote stay, and copies someone already made
  are out of our hands.

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
