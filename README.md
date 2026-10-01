# LessMTP — native iOS Gmail client

A native SwiftUI Gmail client, signed in with your own Google account via OAuth.
Purely an email app — inbox/archive, read, reply (inline, chat-bubble style for a
back-and-forth thread), forward, compose, archive/unarchive, mark read/unread,
search, and attachments (download + QuickLook preview).

## One-time setup: Google Sign-In

Google blocks OAuth inside a plain embedded web view, so this app needs its own
**iOS** OAuth client (a "Web application" client won't work here).

1. Go to [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials).
2. **Create Credentials → OAuth client ID → iOS**.
3. **Bundle ID**: `com.afbrh.LessMTP`
4. Click Create. Copy the new **Client ID** (looks like
   `123456789-abc123.apps.googleusercontent.com`).
5. Open `RysTools/Networking/GoogleAuthService.swift` and replace
   `YOUR_IOS_CLIENT_ID.apps.googleusercontent.com` with that Client ID.
6. Open `RysTools/Info.plist` and replace `YOUR_IOS_CLIENT_ID` (inside
   `CFBundleURLSchemes`) with just the numeric prefix of that Client ID — the part
   before `.apps.googleusercontent.com`. Example: if your Client ID is
   `123456789-abc123.apps.googleusercontent.com`, the URL scheme becomes
   `com.googleusercontent.apps.123456789-abc123`.
7. Make sure your Google account is added as a test user on this OAuth consent
   screen, if it's still in Testing mode.

The scopes requested are `userinfo.email`, `gmail.readonly` (mail itself is
read/written through the Gmail API's send/modify endpoints, which this readonly
scope's *label* undersells — see GoogleAuthService's own scope list if that ever
needs auditing), and `contacts.readonly`/`contacts.other.readonly` (so a sender's
name in the list matches whatever Gmail itself already shows, sourced from your
real Google Contacts).

## Running it

Open `RysTools.xcodeproj` in Xcode, pick your iPhone (or a simulator) as the run
destination, and hit Run. To install on your own phone over USB/Wi-Fi instead of
the simulator: plug it in, select it as the destination, and Xcode will ask you to
trust your Apple ID's developer certificate on the phone the first time
(Settings → General → VPN & Device Management) — a free Apple ID works for this,
no paid Developer Program needed, but the app will need re-installing from Xcode
about once a week unless you enroll in the paid program (which issues certs that
last a year).
