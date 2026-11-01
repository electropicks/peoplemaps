# PeopleMaps privacy policy

Version 1, drafted 31 October 2026, for the app version that adds problem
reports. This is the plain-language version of what the app does with your
information. The engineering details are in `Docs/REPORTS.md`; if the two
ever disagree, the engineering document is the one being built from and this
one is wrong and gets fixed.

> **Draft, not published.** Two things to settle first (`Docs/REPORTS.md`): what
> Cloudflare's logs record, checked on the deployed server (4.6), and "in the
> United States" below, since the database was created with a location hint,
> which Cloudflare says is not a guarantee (question 25).

## The short version

- The app works offline. Maps, search and routes are on your phone.
- Nothing leaves your phone unless you tap **Send** on a report you have
  read.
- There are no accounts, no sign-in, no analytics, no ads, no tracking.
- A report you send is stored on our server and read by a maintainer. Nothing
  is published automatically. A maintainer may file a useful report as a public
  GitHub issue by hand, without your exact locations or report ID.
- You can see, export and delete everything on the phone, and delete what you
  sent from our server. The app contacts the server only when you tap Send,
  Check status or Delete my reports.

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

The app asks for your location once, the first time the home map shows.
While the app is open it uses your location to start routes and time
estimates from where you are, and, while guiding, to show where you are on
the map and say the next turn. It stops when the app leaves the screen. Your
location is never collected by us, except inside a report you send with
**Exact locations** turned on.

## What leaves your phone, and only when you tap Send

Nothing is sent automatically. Flagging is silent and offline. Sending a
report needs a connection and happens only from the **Flagged moments**
list, after you have picked a category, optionally written one sentence, and
looked at every field. The app contacts our server at exactly three moments,
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
- **Exact start, destination and your position when you flagged**, only if
  you turn on **Exact locations** for that report. It is off by default.
  Turn it on when a snapped report would not show the problem, for example
  when the trouble is the first turn out of a driveway.
- **Where along the route you were** when you flagged: a step number, a
  distance along it, and which half-kilometre square of Seattle that point
  is in. Not a coordinate.
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

## Your report ID

The first time you send a report, the app asks our server for a random ID
and a secret key for it. The ID links your reports together so you can delete
them. It is not tied to you, your Apple ID or your phone, and it is not
backed up or restored to another phone. In **Flagged moments** you can see it,
or delete it with all your reports. There is no separate way to change it: after
**Delete my reports**, your next report gets a new ID.

## Where a report goes

1. **Our server**, a Cloudflare Worker and database in the United States, run by
   the people who make PeopleMaps. It stores the report for 90 days. Exact
   locations are kept apart from the rest, and only people with access to the
   project's Cloudflare account can read them. After 90 days the report is
   deleted, and Cloudflare can still restore it for 7 more days (see Deleting).
2. **A public GitHub issue**, only if a maintainer reads your report, finds it
   useful and files one by hand at `github.com/electropicks/peoplemaps`. The
   server never does this. An issue contains your report except for your exact
   locations and report ID, with your start and destination shown only as
   half-kilometre squares. It can include your sentence, which the maintainer
   may edit or leave out, and the route's street list, so someone with map data
   can still find the snapped corners where the route begins and ends. Issues
   are public to anyone on the internet, and GitHub emails them to people who
   watch the project.

We never store or log IP addresses; Cloudflare necessarily sees them to
deliver traffic. The server does not log requests or their headers, has
Cloudflare's per-request logging turned off, and sets no cookies. Cloudflare
sees your connection the way any website's host does; we do not receive
that. Cloudflare also
applies connection rate limits at its edge, so that one source cannot flood
the server; those counts live in its memory for a minute and we store
nothing from them.

## Deleting

- **On the phone**: swipe a flagged moment away, or delete them all. This
  does not contact the server.
- **On the server**: **Delete my reports** shows how many sent reports it will
  remove, asks you to confirm, then removes every report under your ID and the
  ID itself.
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
  7 days after you delete it, and a report that expired is gone 7 days after
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
