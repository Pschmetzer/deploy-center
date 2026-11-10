# The iOS app on the App Store: checklist

Deploy Center for iPhone and iPad is free, with no in-app purchases. This list has two parts: what
is ready in the repo, and what only the owner can do in the Apple Developer account. The decisions
behind the app are in `docs/WIDGETS-IOS.md`.

## Ready in the repo

| Item | Where |
|---|---|
| Xcode project (app + widget extension) | `ios/DeployCenter.xcodeproj` (folders `ios/App`, `widgets`, `shared`) |
| Simulator build, archive and export | `ios/build.sh`, `ios/build.sh --archive` |
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
| Screenshots, 6.9" iPhone and 13" iPad | `ios/AppStore/screenshots/` (demo data, native size) |
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

0. **Status (2026-11-10):** the App IDs `app.deploycenter.ios` and `app.deploycenter.ios.widgets`
   exist, with App Store profiles; `ios/build.sh --archive` exports a signed `.ipa`. The App Group
   capability is **not yet** on the App IDs, so that build has no App Group: enable "App Groups"
   on both App IDs in Certificates, Identifiers & Profiles, register `group.app.deploycenter`,
   then archive again. The team has no registered devices, so the archive is unsigned and signed
   ad hoc with the entitlements before the export (see the comment in `ios/build.sh`).
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

3. **Archive and upload.** Archive with:

   ```bash
   ios/build.sh --archive
   ```

   Upload `build/ios-export/DeployCenter.ipa` with the Transporter app, or with an App Store
   Connect API key:

   ```bash
   xcrun altool --upload-app -f build/ios-export/DeployCenter.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
   ```

   - The key belongs outside the repo, in `~/.appstoreconnect/private_keys/`.
   - Raise `CURRENT_PROJECT_VERSION` for every upload.
4. **TestFlight.** Install the build on your own iPhone and add a real token. Then check:
   - deploy one project and roll it back;
   - a widget;
   - a background note.
5. **Submit.** Paste the texts and the review notes, add the screenshots, then submit for review.

## Before each release

1. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project.
2. Run `ios/build.sh`, and check the demo on an iPhone and an iPad simulator.
3. When a screen has changed, make new screenshots. Launch with `-demo`; `-open <project>` and
   `-settings` open a screen directly:

   ```bash
   xcrun simctl launch booted app.deploycenter.ios -demo -open Harbor-307
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
