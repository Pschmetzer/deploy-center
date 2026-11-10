# The iOS app on the App Store: checklist

Deploy Center for iPhone and iPad is free, with no in-app purchases. This list has two parts: what
is ready in the repo, and what only the owner can do in the Apple Developer account. The decisions
behind the app are in `docs/WIDGETS-IOS.md`.

## Ready in the repo

| Item | Where |
|---|---|
| Xcode project (app + widget extension) | `ios/DeployCenter.xcodeproj` (folders `ios/App`, `widgets`, `shared`) |
| Simulator build, archive and export | `ios/build.sh`, `ios/build.sh --archive` (build number from the commit count) |
| Logic checks without a device | `ios/test.sh`: the "waiting" rule, rollback targets, GitHub reads, against made-up answers |
| Not offered on Mac or Apple Vision Pro | `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`, `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = NO`; the store switch is separate, see below |
| Privacy manifest | `ios/App/PrivacyInfo.xcprivacy`: no tracking, no collected data, UserDefaults reason `CA92.1` |
| Face ID usage text | `NSFaceIDUsageDescription` in the target's build settings |
| Background refresh | `ios/Config/Info.plist` (`BGTaskSchedulerPermittedIdentifiers`, `UIBackgroundModes: fetch`) |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` (only HTTPS through the system) |
| App icon | `ios/App/Assets.xcassets/AppIcon.appiconset`, 1024 px, no alpha, made from the Mac icon |
| Launch screen | generated (`UILaunchScreen`), system background |
| iPhone and iPad layout, dark mode | `NavigationSplitView`, system colours; checked in the simulator (`ipad-13-4-dark.png`) |
| Dynamic Type, VoiceOver | system text styles, scaled icons, the summary in two rows at accessibility sizes (checked); combined accessibility elements, **VoiceOver not yet checked** |
| Demo mode for review (Guideline 2.1) | "Try the demo" on the first screen, or Settings → Demo mode |
| Store texts, English and German | `ios/AppStore/en.md`, `ios/AppStore/de.md` |
| Review notes | `ios/AppStore/en.md`, section "Notes for App Review" |
| Screenshots, 6.9" and 6.3" iPhone, 13" iPad | `ios/AppStore/screenshots/` (demo data, native size) |
| Privacy policy with an iOS section | `site/datenschutz.html`, URL https://deploycenter.app/datenschutz.html |

### Review risks and how they are handled

- **2.1 App completeness:** a reviewer has no Vercel or Render account.
  - The demo mode shows every screen.
  - In the demo, a deploy or rollback is simulated after Face ID.
  - The review notes say so.
- **4.2 Minimum functionality:** the app deploys, rolls back, follows builds, has widgets and sends
  notes. It is not a wrapped website.
- **5.1.1 Data collection:** there is no account and no server, and tokens stay on the device. The
  privacy answer is "Data Not Collected".
- **5.2 / 2.3.7 Intellectual property and metadata:**
  - there are no Vercel, Render or GitHub logos in the app or in the screenshots;
  - the name, subtitle and keywords leave out third-party names; adding them there is the owner's call;
  - the names are used only to say what the app works with;
  - the store text says the app is not affiliated with them.
- **2.5.1 Software requirements:** public APIs only, no private frameworks, no downloaded code.

## Steps only the owner can do (ask before each)

0. **Status (2026-11-10):** done:
   - The App IDs `app.deploycenter.ios` and `app.deploycenter.ios.widgets` exist, with App Groups on and
     `group.app.deploycenter`, and App Store profiles.
   - The App Store Connect record exists: **"Deploy Center: Hand Deploys"**, because "Deploy Center" is
     already taken on the store. SKU `deploycenter-ios`, English (U.S.). The name can be changed
     before review. The name under the icon stays "Deploy Center".
   - Builds are uploaded with `ios/build.sh --archive`, then `--upload`; the table under
     "Submissions" names the one in review.

   - The store page is filled in, in English (U.S.) and German: subtitle, promotional text,
     description, keywords, support and marketing URL, copyright, and 3 screenshots each for the
     6.3" iPhone and the 13" iPad (`ios/AppStore/screenshots/`; the German page uses the English ones).
     Category Developer Tools, secondary Productivity. Age rating 4+ (all "None"). Price free, in all
     175 countries. "Sign-in required" is off.
   - App Privacy: privacy policy URL set, answer "Data Not Collected" saved but **not published**.

   Still open, for the owner:
   - App Privacy → **Publish** (it is your statement that the answers are correct).
   - App Information → **Content Rights** (a legal statement about third-party content).
   - Version page → App Review: your contact (name, phone, email), then paste the review notes from
     `ios/AppStore/en.md`. The notes cannot be saved without the contact.
   - TestFlight: the internal group "Owner" has the uploaded build, and the account holder is invited.
     Accept the invite in the TestFlight app, add a real token, then submit.

   The team has no registered devices, so the archive is unsigned and signed ad hoc with the
   entitlements before the export (see the comment in `ios/build.sh`).
1. **App IDs and the App Group.** Register `app.deploycenter.ios` and `app.deploycenter.ios.widgets`,
   with the App Group `group.app.deploycenter` on both. `ios/build.sh --archive` uses
   `-allowProvisioningUpdates` and can create them itself, so the first archive is itself an
   account action.
2. **App Store Connect record.** New App → iOS, with these values:

   | Field | Value |
   |---|---|
   | Name | Deploy Center |
   | Primary language | English (U.S.) |
   | Bundle id | `app.deploycenter.ios` |
   | SKU | your choice |
   | Price | free |
   | Category | Developer Tools; secondary: Productivity |
   | App Privacy | "Data Not Collected" |
   | Privacy policy URL | https://deploycenter.app/datenschutz.html |
   | Age rating questionnaire | all "None", which gives 4+ |
   | Pricing and Availability | turn off "iPhone and iPad Apps on Apple Silicon Macs" and "Apple Vision Pro": the Mac has its own app |

3. **Archive and upload.** Archive with:

   ```bash
   ios/build.sh --archive
   ```

   Upload with the Apple ID signed in to Xcode:

   ```bash
   ios/build.sh --upload
   ```

   Or upload `build/ios-export/DeployCenter.ipa` with the Transporter app, or with an App Store
   Connect API key:

   ```bash
   xcrun altool --upload-app -f build/ios-export/DeployCenter.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
   ```

   - The key belongs outside the repo, in `~/.appstoreconnect/private_keys/`.
   - The build number is the commit count of `HEAD`, so it grows with every commit on `main`.
     `BUILD_NUMBER=… ios/build.sh --archive` sets one by hand.
4. **TestFlight.** Install the build on your own iPhone and add a real token. Then check:
   - deploy one project and roll it back;
   - a widget;
   - a background note.
5. **Submit.** Paste the texts and the review notes, add the screenshots, then submit for review.

## Before each release

1. Raise `MARKETING_VERSION` in the project (the build number comes from `ios/build.sh --archive`).
2. Run `ios/test.sh` and `ios/build.sh`, and check the demo on an iPhone and an iPad simulator.
3. When a screen has changed, make new screenshots. Launch with `-demo`; `-open <project>` and
   `-settings` open a screen directly:

   ```bash
   xcrun simctl launch booted app.deploycenter.ios -demo -open Harbor-307
   ```

   For the German store page, the same in German:

   ```bash
   xcrun simctl launch booted app.deploycenter.ios -demo -open Harbor-307 -AppleLanguages "(de)" -AppleLocale de_DE
   ```

   Then capture it:

   ```bash
   xcrun simctl io booted screenshot shot.png
   ```

4. Check that the pbxproj holds no team id:

   ```bash
   grep -nE "DEVELOPMENT_TEAM = [A-Z0-9]{10}" ios/DeployCenter.xcodeproj/project.pbxproj
   ```

   It must print nothing.

## Submissions

| Date | Version (build) | Status |
|---|---|---|
| 2026-11-10 | 1.0 (2), with the Mac connection | Submitted for review; released automatically after approval |

Checked before submitting: the QR connection on a real iPhone (TestFlight build 2). Not yet checked
on a device: the iCloud Keychain connection. Each localization needs its own privacy policy URL
(App Privacy → language menu); German had none at first and blocked "Add for Review".
