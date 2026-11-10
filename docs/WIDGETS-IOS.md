# Widgets and the iOS app: the decisions

Status:
- **Mac widget:** builds, and is signed locally. Small, medium and large.
- **iOS app:** list, details, deploy, cancel and rollback with Face ID, background notes, widgets on the
  Home Screen (small to extra large) and the Lock Screen. Connects to the Mac app through iCloud
  Keychain or a QR code. In TestFlight; the QR code was tried on a real iPhone (see "What was verified").

The Mac widget is decision 1; everything after it is about the iOS app.

Steps in the owner's Apple Developer account are listed at the end and in `docs/APP-STORE.md`.

## Decision 1: how the Mac widget gets into the app

**Chosen: build the extension with `swiftc` in `build.sh`, opt-in with `--widgets`.**

| | swiftc in build.sh (chosen) | XcodeGen for the extension | Whole Mac build as an Xcode project |
|---|---|---|---|
| New tools | none | XcodeGen on every build Mac | none, but a `.xcodeproj` |
| Plain build | unchanged, no Xcode needed | unchanged | needs Xcode; everything changes |
| Signing | in our script, visible | Xcode's automatic signing | Xcode's |
| Risk | Xcode-only steps later (App Intents metadata for configurable or interactive widgets) | a second build system | the biggest change |

- `./build.sh` without the flag builds what it built before. There is no `PlugIns` folder.
- `./build.sh --widgets` compiles `widgets/*.swift` and `shared/*.swift` into
  `Contents/PlugIns/DeployCenterWidgets.appex`. It signs in this order:
  1. the extension, with the sandbox and the App Group;
  2. the app, with the App Group, without `--deep`.
- A WidgetKit extension needs nothing Xcode-only:
  - `-application-extension`;
  - a normal `@main` (`LC_MAIN`, like Apple's own widgets);
  - `CFBundlePackageType = XPC!`;
  - `NSExtensionPointIdentifier = com.apple.widgetkit-extension`.

### How the Mac widget gets its data

After each reload of the lists or the costs, the app writes `snapshot.json` into the App Group
container. The file is a few KB; its format is `shared/DeploySnapshot.swift`. The app then asks
WidgetKit to reload, and only when something changed.

- **App Group:** `<TEAMID>.app.deploycenter`. On macOS a group prefixed with the team id needs no
  provisioning profile.
  - `build.sh` takes the team id from the signing identity.
  - It writes the team id into the entitlements and into an Info.plist key (`DCAppGroup`).
  - No team id lives in the repo.
- **Ad hoc build** (`DEVELOPER_ID=-`): there is no group, so nothing is written. The gallery preview
  shows sample numbers.
- **Demo mode** masks names and commit messages in the snapshot.
- **A tap** opens `deploycenter://`.
- **Small widget:** waiting PRs, projects, building and failed. **Medium:** the same, plus the top 3
  projects and the saving a month.

## Decision 2: where the iOS app gets its data, and how it deploys

The goal: see what waits, deploy, roll back and get notes on the go, also while the Mac sleeps.
There is no server of ours.

| | **A: the phone talks to the APIs (chosen)** | B: a command queue in iCloud, the Mac runs it |
|---|---|---|
| Works with the Mac asleep or off | yes | no, waits for the Mac |
| Tokens on the phone | yes, in the keychain, this device only | no |
| Apple account steps | none beyond the App ID | iCloud container + Developer ID profile for the Mac app |
| Same "waiting" rule as the Mac | ported from `deploys` | the Mac's own |
| Deploy safety | Face ID on the phone, then the provider's API | the Mac would have to confirm (remote execution) |

**Chosen: A.** The app calls `api.vercel.com`, `api.render.com` and `api.github.com` with the
person's own tokens. These are the endpoints the `deploys` CLI uses:

- **Vercel**
  - Lists: `/v10/projects`, and `/v6/deployments?target=production` for the newest attempt.
  - Deploy: `POST /v13/deployments` with `gitSource {type: github, ref, repoId}`.
  - Status: `GET /v13/deployments/{id}`.
  - Rollback: `POST /v1/projects/{id}/rollback/{deployment}`. The target is the previous READY
    production deploy of a different commit.
  - Turning auto-deploy off removes the Git link. The repo then comes from the live deploy's
    `meta.githubCommit*`.
- **Render**
  - Lists: `/services` and `/services/{id}/deploys`.
  - Deploy: `POST /services/{id}/deploys`.
  - Rollback: `POST /services/{id}/rollback`. The target is the newest deactivated deploy of
    another commit.
  - POSTs are never retried.
- **GitHub**
  - The branch head, and `compare/{live}...{branch}` for the commits that wait.
  - PR numbers from the commit messages: `(#12)` or `Merge pull request #12`.
  - For up to ten commits without a number: `commits/{sha}/pulls`.
- **"Waiting"** uses the rule from `deploys`. A project waits when all of these hold:
  - it is deployable and not paused;
  - it is not building;
  - its head is known and there was no read error;
  - it is not behind;
  - the live commit differs from the head.

Also considered, and not chosen: a GitHub workflow (`integrations/action` with `deploy: true`),
started by `workflow_dispatch`.
- It needs a workflow file in each repo.
- It needs a token with `actions:write`.
- It deploys every changed project, not the one tapped.

**B stays optional** and is not built. It only helps people who do not want tokens on the phone,
and it needs the iCloud account steps.

### Notes while the app is closed

Without a server this is best effort.
- **Background refresh:** a `BGAppRefreshTask` reads the lists and posts a local notification for
  what newly waits or failed. iOS decides when it runs, usually a few times an hour at most. The
  settings screen says so.
- **Following a deploy:** the app polls the deploy it started. When it goes to the background, a
  background task buys about half a minute, and on iOS 26 a continued processing task keeps going with
  a progress in the system, until the deploy ends or iOS stops it. The end comes as a notification.
- **Live Activity:** none yet. One started by the app is possible without a server, but it only
  updates while the app runs; one that updates while the app is closed needs push from a server (APNs).

### Tokens and Face ID

- Tokens typed on the phone are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
  - never synced, and not in backups;
  - readable by the background refresh after the first unlock.
- Tokens from the Mac come through iCloud Keychain (decision 4). A token typed on the phone wins.
- Every deploy, cancel and rollback asks twice:
  1. a confirmation that names what goes live (the newest commit, how many commits and PRs);
  2. `LAContext` with `.deviceOwnerAuthentication`: Face ID, Touch ID or the passcode.
- What Face ID protects, honestly: a deploy started by a slip of the finger, or by someone holding the
  unlocked phone for a moment. It is a check in the app, not a lock on the keys: whoever controls the
  unlocked device (or a jailbroken one) can read the app's keychain items without it.
- The app follows the language iOS picks for it (Settings → Deploy Center → Language), English or
  German; the widgets follow the app.

## Decision 3: how the iOS app is built

**Chosen: a small hand-written Xcode project, `ios/DeployCenter.xcodeproj`. No XcodeGen.**

- It uses Xcode 16+ folder-synchronized groups. The project file names three folders and no
  single file:
  - `ios/App`;
  - `widgets` (the same widget code as the Mac);
  - `shared`.
- An App Store build needs a project anyway: archive, export, provisioning.
- The earlier `swiftc` script for the simulator is gone. `ios/build.sh` now wraps `xcodebuild`.
- Two Info.plist entries cannot be generated from build settings. They live in `ios/Config/`:
  - the background refresh keys, in `Info.plist`;
  - the widget's `NSExtension`, in `Widgets-Info.plist`.

```bash
ios/build.sh --run
```

```bash
ios/build.sh --archive
```

What `--archive` does:
- it takes the team id from the signing identity at build time;
- it exports an `.ipa` and uploads nothing;
- it uses `-allowProvisioningUpdates`, which may register the App IDs and profiles in the account.
  So it only runs after the owner agrees.

More about the iOS build:
- **iOS App Group:** `group.app.deploycenter`. There is no team id in the name. It has to be
  registered once.
- **iOS widget:** the Mac widget's code, built for iOS. The app writes the snapshot after each
  reload. In the simulator the widget installs with the app; on a device it needs the App Group
  registered.

## Decision 4: the iPhone app connects to the Mac app

**Chosen: the Apple ID is the account. The Mac hands its keys over through iCloud Keychain, or as a
QR code. No account and no server of ours.**

An own account with a server would hold every user's deploy tokens: a large liability, and the end
of "Data Not Collected".

- **iCloud Keychain** (`shared/PhoneLink.swift`): Mac app → Settings → iPhone → "Connect the iPhone
  app". It writes one synchronizable keychain item in the team's keychain group
  `<TEAMID>.app.deploycenter.shared`: the Vercel token made for the phone, the Vercel team id, the
  Render key and the gh CLI's GitHub token. iCloud Keychain carries it, end-to-end encrypted, to the
  devices with the same Apple ID. Turning the switch off removes it everywhere.
  - The vercel CLI's own login is short-lived (it has `expiresAt`), so the phone gets a separate,
    long-lived Vercel token, saved in the Mac app.
  - macOS allows the keychain group only with an embedded provisioning profile: the Developer ID
    profile of `app.deploycenter.mac`. `build.sh` embeds it from `DC_MAC_PROFILE` or
    `~/.config/deploys/mac-developer-id.provisionprofile` (never in the repo, it names the team).
    Without it the Mac app builds without the iCloud link.
  - iOS: `keychain-access-groups` in `ios/Config/DeployCenter.entitlements`; the group name comes
    from the Info.plist key `DCKeychainGroup` (`$(DEVELOPMENT_TEAM)`), so simulator builds without a
    team have no link. `ios/build.sh --archive` fills in `$(AppIdentifierPrefix)` before its ad hoc
    signature.
- **QR code**: the Mac shows the same keys as a QR code for 60 seconds, on request. The iPhone app
  scans it in "Connect to the Mac" (camera inside the app; or "Paste" for the code's text), shows what
  the code holds, and keeps the keys on the phone only after "Connect".

### The QR code: what it holds and who can read it

- **What is in it:** the Vercel token made for the phone, the Vercel team id, the Render key, the gh
  CLI's GitHub token, and the time it was made. Base64 JSON behind `deploycenter-link:1:`. Not
  encrypted: anyone who can read the code has the keys.
- **Who can read it:** any camera that sees the Mac's screen while it shows (60 seconds): a person
  behind you, a video call sharing the screen, a screen recording. The Mac says "show it to no one".
- **How long it works:** the iPhone app refuses a code made more than five minutes ago (to allow for
  clocks that differ a little). A photo of the screen is useless after that, to this app. The keys
  in it stay valid as long as the provider keeps them.
- **How to revoke:** delete the token at Vercel (Account → Tokens), the key at Render (Account
  Settings → API Keys), or the GitHub token. On the phone, "Delete the keys on this iPhone" removes
  the copies there.
- **Not done:** encrypting the code with a short number typed on the phone. It would cost a step for
  everyone; the five-minute limit covers the photo case.

### When iCloud Keychain brings nothing

| What you see | Usual cause | Fix |
|---|---|---|
| "Not available in this build" | the build has no team id (simulator, a build from source) | use the QR code |
| "Nothing arrived yet" for minutes | iCloud Keychain (Passwords) is off on the Mac or the iPhone | System Settings / Settings → Apple Account → iCloud → Passwords |
| The same, with Passwords on | the Mac and the iPhone use different Apple Accounts | sign in with the same one, or use the QR code |
| The Mac says it could not write (error −34018) | the Mac app was built without its Developer ID profile | install the released app, or use the QR code |
| "The key from the Mac was refused" | the Mac's token was deleted or expired | make a new one in the Mac app (Settings → iPhone) |

### What else the iPhone app does (reads only, unless it says Face ID)

- **Build log (IOS-118).** A failed project, and each deploy in its history, shows the build log from
  shortly before the first error line (else the last lines). Vercel: the deployment's events, Render:
  the build logs in the deploy's time window, the same calls as `deploys logs`. Secrets are masked by
  `ios/App/LogMask.swift`, a port of `af_mask` in `deploys` with the same rules in the same order.
  The whole log is masked before anything is cut, kept, shown or copied; if a pattern does not
  compile, nothing is shown. "Copy" puts the masked log on this device's clipboard only, for ten
  minutes. Tests: `ios/Tests/run.sh` (swiftc, no simulator) compares the port line for line with
  `af_mask`'s own output for the same text (`ios/Tests/fixtures/mask-out.txt`). When `af_mask`
  changes, regenerate that file with it and keep the port in step.
- **History (IOS-120).** The last 15 production deploys; a built one can go live again (a rollback to
  it, with Face ID).
- **Render services (IOS-132).** Pause, resume, restart, each with Face ID.
- **Live Activity (IOS-122).** A deploy or rollback started in the app shows on the lock screen and
  in the Dynamic Island, with its state and a running clock. There is no push server: it is updated
  only while the app runs; after 90 seconds without an update it says how old it is and to open the
  app. `ios/Common/DeployActivity.swift` is built into the app and the extension.
- **Siri and Shortcuts (IOS-123).** "What waits in Deploy Center", "Failed deploys in Deploy Center":
  answered from the state the app saved last, with its age. No deploy by voice: a deploy asks for
  Face ID in the app.
- **Quick actions, Spotlight, Handoff (IOS-133, IOS-129).** The app icon's menu has Refresh and the
  projects that need a look. Projects are in Spotlight (not in demo mode). An open project continues on
  another iPhone or iPad; the Mac app does not take it yet.
- **Notification actions (IOS-124).** Open, and Mute for today (news from the background refresh only;
  the end of a deploy started in the app still comes).
- **Widgets.** A second widget, "Failed deploys", lists only what failed or builds (Mac and iPhone).
  On iOS 18 a control for Control Center, the lock screen and the Action button shows the waiting PRs
  and opens the app; it reads the snapshot only, the extension holds no keys.

### Privacy manifest (IOS-114)

`ios/App/PrivacyInfo.xcprivacy` declares the required-reason APIs the app uses: `UserDefaults`
(CA92.1, the app's own settings) and file timestamps (C617.1: the modification date of the app's own
`last-projects.json`, for "as of"). The widget extension has no manifest of its own because it uses none
of these APIs: it reads the snapshot file's contents, not its dates, and no `UserDefaults`. Check
again when the extension or `shared/` start using `UserDefaults`, file dates, disk space or uptime.

## What was verified, and what not

Verified on this Mac:
- **Plain build:** `./build.sh --fast` builds without `PlugIns`. App tests pass; shellcheck is clean.
- **Widget build:** `./build.sh --fast --widgets` with the Developer ID.
  - The app carries the App Group.
  - The extension carries the sandbox and the App Group.
  - `codesign --verify --strict --deep` passes.
  - `pluginkit` lists the extension.
- **Real accounts, read-only:** the app's API code (`ios/App/Clients.swift`, `Project.swift`),
  compiled for macOS, read the owner's Vercel, Render and GitHub accounts with GET requests only:
  - it found the same waiting projects as `deploys changed --json`;
  - it found the same commit and PR counts for each of them;
  - it had no read errors.
  Deploy and rollback were not tried against real accounts.
- **iOS:** the app and its widget extension build with `xcodebuild` for the simulator. They run in
  demo mode on an iPhone 17 Pro Max and an iPad Pro 13" simulator. The screenshots are in
  `ios/AppStore/screenshots/`.

- **Mac link:** the Mac app, signed with the Developer ID profile, launches, and writes and reads
  the synchronizable item in the shared keychain group.
- **New in this round (simulator only):** everything above builds for the simulator and the Mac
  widget still builds with `./build.sh --widgets`. The build log with its masking was seen in demo
  mode. The Live Activity, the control, quick actions, Siri and the notification actions were not tried
  on a device, and the log, history and Render calls not against real accounts.
- **QR code:** TestFlight build 2 on the owner's iPhone connected to the Mac app by scanning its
  code.

### Test plan for real deploys (owner, with a throwaway project)

Use one Vercel project and one Render service made for this, with auto-deploy off.
1. **Deploy:** push a commit, wait for "waiting", deploy from the phone. Expect "is live" and the row
   back in "Up to date".
2. **Cancel:** deploy again, tap "Cancel the build" while it builds. Expect "canceled", and the old
   deploy still live.
3. **Rollback:** roll back. Expect the previous commit live (Vercel: the domain points to it; Render:
   a new deploy of the old commit).
4. **Background:** start a deploy and lock the phone. Expect a notification at the end (iOS 26), or
   the right state when the app opens again.
5. **Lost answer:** start a deploy in Airplane Mode right after tapping "Deploy" (hard to time):
   the app should find the running deploy instead of saying it failed.
6. **Timeout:** a build longer than 20 minutes ends with "no final state", not silence.

Not verified:
- **iCloud Keychain between Mac and iPhone:** needs TestFlight build 2 on a real iPhone.
- **The widget gallery:** the Mac widget was not opened there. That needs the screen, and this
  session had no access to it. To check: right-click the desktop → Edit Widgets → search "Deploy".
- **Real deploys:** deploy, cancel, rollback and the status polling never ran against real accounts
  (test plan above). The continued processing task (iOS 26) builds but was not tried on a device.
- **Vercel teams:** with several teams and no team id set, the app reads the personal account.
  The settings screen has a field for the team id.
- **Simulator:** Face ID, the background refresh, notifications, the Lock Screen widgets and the iOS
  widget on the Home Screen were not tried. To start the background refresh in the debugger: pause
  the app and run
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"app.deploycenter.ios.refresh"]`,
  then continue. VoiceOver was not tried either. Large text (accessibility sizes) was
  checked: the summary switches to two rows.
- **Device and store:** no device build. Build 1.0 (1) is archived (ad hoc signed, see `ios/build.sh`) and uploaded; the store page is filled in. Status: `docs/APP-STORE.md`.

## Steps only the owner can do (Apple Developer account)

1. **Mac App Group.** Decide whether a Mac release may carry the App Group
   (`<TEAMID>.app.deploycenter`). Then run one notarized test build with `--widgets`.
2. **iOS App IDs.** Register the App IDs `app.deploycenter.ios` and `app.deploycenter.ios.widgets`,
   and the App Group `group.app.deploycenter`. `ios/build.sh --archive` can also do this, through
   `-allowProvisioningUpdates`.
3. **App Store Connect.** Create the record (free, Developer Tools). Fill in:
   - the texts from `ios/AppStore/`;
   - the privacy answers ("Data Not Collected");
   - the review notes.
4. **Release.** Upload the build, test it in TestFlight, then submit. Details: `docs/APP-STORE.md`.
