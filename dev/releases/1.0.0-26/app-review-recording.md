# App Review recording — Vigil 1.0.0 (26)

> Last reviewed: 2026-08-14
>
> Review again: if Apple asks for a different flow or a new review account

This is the physical-device recording Apple asked for under Guideline 2.1.
Record on the iPhone after TestFlight build **26** is installed. A simulator
recording does not count.

Apple wants one continuous video that starts at launch and shows the real
product. Vigil has no Vigil account, in-app purchase, user-generated content,
or camera/location/contacts/tracking prompts. Those absences are correct.
Do not invent extra flows.

## What the video must prove

1. The app launches on a physical iPhone.
2. A person can connect a provider account (Grok Build device sign-in).
3. The dashboard and account detail show live provider data.
4. Manual refresh works.
5. Settings, privacy, and the optional app lock work.
6. The connected account can be removed from this device.

## Before you press Record

Do this off camera.

1. Install **Vigil 1.0.0 (26)** from TestFlight. Confirm the TestFlight screen
   says build **26**.
2. Update the iPhone to the latest iOS it will take.
3. Remove every existing Vigil account, or delete and reinstall Vigil, so
   launch shows the empty first-run screen.
4. Have the dedicated Grok Build review account ready. That is the account
   already stored in App Store Connect's protected demo fields.
5. Put the phone in portrait, silent, and Do Not Disturb.
6. Close other apps. Keep the Home Screen visible.
7. Remember: the one-time Grok code is secret. If you will share the file
   outside App Store Connect, blur that code later. Apple already has the
   review account, so they can complete the same flow themselves.

## Record this, in this order

Start Screen Recording from Control Center, then:

### 1. Launch

1. Show the iPhone Home Screen.
2. Tap **Vigil**.
3. Leave the empty first-run dashboard on screen for two seconds.

### 2. Connect Grok Build

1. Tap **Connect Grok Build**.
2. Wait until the device code appears.
3. Tap **Open sign-in page**.
4. On xAI's page, sign in with the dedicated review account, approve access,
   and enter the one-time code.
5. Return to Vigil and wait until the dashboard shows the Grok Build card
   with a weekly percentage or reset. Do not stay on a spinner.

If sign-in fails, stop recording, fix the account, and start over. A failed
login is not the review video.

### 3. Core usage

1. Tap the Grok Build card.
2. Scroll account detail slowly enough to show windows, credits, reset time,
   freshness, and any observed history.
3. Go back to Home.
4. Pull down to refresh and wait until it finishes.

### 4. Settings

1. Open **Settings**.
2. In **Appearance**, switch **System → Light → Dark → System**.
3. Turn **Hide usage values in widgets** on, then off.
4. Turn **Hide notification details** on, then off.
5. Turn **Pause automatic checks** on, then off.
6. Turn **Require Face ID or Touch ID** on.
7. If Face ID or passcode appears, complete it. That is the only sensitive
   permission Vigil can show.
8. Leave Settings.

### 5. Lock and unlock

1. Swipe up to the Home Screen or App Switcher, then open Vigil again.
2. When **Vigil is locked** appears, tap **Unlock** and authenticate.
3. Confirm the dashboard is visible again.

### 6. Delete the connection

1. Open **Accounts**.
2. Choose the Grok Build account.
3. Remove it and confirm.
4. Show the empty dashboard again for two seconds.
5. Stop the recording.

## Length and file

- Aim for two to four minutes. Do not narrate unless you want to.
- Keep it one take. If you fumble a tap, start over.
- Save the video on the iPhone, then get it onto the Mac you use for App
  Store Connect.
- Do not commit the video or any review-account values to Git.

## After the recording

1. Write the iPhone model and iOS version into section 2 of
   [`guideline-2.1-reply.md`](guideline-2.1-reply.md).
2. Paste that file into App Store Connect → App Review Information → Notes.
3. Attach or link the recording in the review reply as Apple asked.
4. Keep the Grok Build review account active until review finishes.
