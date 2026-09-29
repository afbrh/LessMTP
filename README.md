# LessMTP — native iOS proof of concept

A native SwiftUI shell around the same Google account data the web tools
(`budget.html`, `email.html`, `cal.html`, `scratch.html` at rys.tools) already use —
same Drive file, same Gmail inbox, same Calendar. This is a first pass, not a full
port: see "What's scoped down" below.

## One-time setup: Google Sign-In

Google blocks OAuth inside a plain embedded web view, so this app can't reuse the
web tools' "Web application" OAuth client — it needs its own **iOS** client.

1. Go to [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials),
   same project the web tools already use (Client ID starting
   `575902569700-...`).
2. **Create Credentials → OAuth client ID → iOS**.
3. **Bundle ID**: `com.afbrh.RysTools`
4. Click Create. Copy the new **Client ID** (looks like
   `123456789-abc123.apps.googleusercontent.com`).
5. Open `RysTools/Networking/GoogleAuthService.swift` and replace
   `YOUR_IOS_CLIENT_ID.apps.googleusercontent.com` with that Client ID.
6. Open `RysTools/Info.plist` and replace `YOUR_IOS_CLIENT_ID` (inside
   `CFBundleURLSchemes`) with just the numeric prefix of that Client ID — the part
   before `.apps.googleusercontent.com`. Example: if your Client ID is
   `123456789-abc123.apps.googleusercontent.com`, the URL scheme becomes
   `com.googleusercontent.apps.123456789-abc123`.
7. This app requests the full `drive` scope (not the web app's narrower
   `drive.file`) specifically so it can find and read the *same*
   `munny-data.json` file the web tools already created — `drive.file` scope is
   siloed per OAuth client, so a brand-new iOS client wouldn't otherwise see it.
   If prompted, make sure your Google account is added as a test user on this
   OAuth consent screen (same place the web app's Testing-mode users are listed).

## Running it

Open `RysTools.xcodeproj` in Xcode, pick your iPhone (or a simulator) as the run
destination, and hit Run. To install on your own phone over USB/Wi-Fi instead of
the simulator: plug it in, select it as the destination, and Xcode will ask you to
trust your Apple ID's developer certificate on the phone the first time
(Settings → General → VPN & Device Management) — a free Apple ID works for this,
no paid Developer Program needed, but the app will need re-installing from Xcode
about once a week unless you enroll in the paid program (which issues certs that
last a year).

## What's scoped down (first pass)

- **Budget**: read-only. Shows each scenario as its own card (Income once at the
  top implicitly via Net, then each locked category + custom row, then Net) —
  no add/remove/clone/rename from the app yet.
- **Email**: inbox list + tap to read full message body. No compose, reply,
  archive, search, or swipe actions yet.
- **Calendar**: the "Upcoming" agenda list only — no month grid, no creating or
  editing events.
- **Scratch**: same boxes, same underlying text format (still saved joined by
  three newlines, so it stays compatible with scratch.html) — editing/adding a
  box works, but the "type three blank lines to split" and "Backspace at the top
  to merge" gestures from the web version aren't replicated; there's a plain
  "+ Add box" button instead.

All four read the *same* Drive file, Gmail inbox, and Calendar the web tools use,
so real data should show up — this was about proving that round-trip and the
overall feel as a native app, not full feature parity yet.
