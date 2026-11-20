# App Store texts: English (en-US)

## Name (30)
Deploy Center: Hand Deploys

("Deploy Center" alone is taken on the App Store.)

## Subtitle (30)
Deploy and roll back anywhere

## Promotional text (170)
See what waits to go live on Vercel and Render, deploy with Face ID, roll back in two taps. Connects to the Mac app. No account of ours, no tracking.

## Description (4000)
Deploy Center shows which of your Vercel projects and Render services have commits that are not live yet, and lets you deploy them by hand, from your iPhone or iPad.

It is made for people who turned off auto-deploy to save build minutes, and still want to ship from anywhere.

WHAT IT DOES
• Lists your projects and services: building, failed, waiting, up to date
• Shows how many commits and merged pull requests wait for each one
• Deploys the newest commit of the production branch, after Face ID
• Rolls back to the previous live deploy, after Face ID
• Follows a deploy until it is live or fails
• Live Activity on the lock screen and in the Dynamic Island while a deploy runs, with a bar over the usual build time
• Widgets for the Home Screen and the lock screen: waiting pull requests, builds and failures, for one platform if you like
• Control Center and Action button: waiting pull requests, or read the list again
• Siri and Shortcuts: "What waits in Deploy Center", failed deploys, open a project or prepare a deploy (it still asks for Face ID)
• Spotlight finds your projects; Handoff continues a project on your other devices
• Optional notes when something newly waits, fails or goes live (checked in the background when iOS allows it)
• Deploy all waiting projects with one Face ID question
• Reads your last history offline

PRIVATE BY DESIGN
• No account and no server of ours: the app talks directly to api.vercel.com, api.render.com and api.github.com
• Connect to Deploy Center on your Mac: it hands over its keys through your iCloud Keychain (end-to-end encrypted) or a QR code. Your Apple ID is the account
• Keys you type in stay in this device's keychain only
• Spotlight and Handoff can be switched off; with "Unlock on open" no project name reaches notifications, Siri or Spotlight. Live Activities on the lock screen still show the project name
• The camera only reads the QR code of the Mac app, and its picture never leaves the device
• No analytics, no tracking, no ads

TRY IT WITHOUT AN ACCOUNT
The demo mode shows made-up projects, so you can see every screen before you add a token.

WHAT YOU NEED
A Vercel access token or a Render API key. A GitHub token is optional and only needed for private repositories.

Deploy Center is open source (MIT) and has a companion app for the Mac.

Deploy Center is not affiliated with, endorsed by or sponsored by Vercel, Render, GitHub or Anthropic.

## Keywords (100)
deployment,devops,ci,cd,rollback,build,hosting,serverless,developer,release,ship,web,api,widget,siri

## Note on names
Third-party names (Vercel, Render, GitHub) appear only in the description, where they say what the app works with. They are kept out of the name, subtitle and keywords (App Review Guideline 2.3.7). Adding them there is the owner's decision.

## Support URL
https://deploycenter.app

## Marketing URL
https://deploycenter.app

## Privacy policy URL
https://deploycenter.app/datenschutz.html

## Copyright
© 2026 Deploy Center contributors

## Category
Developer Tools (secondary: Productivity)

## Age rating
4+ (no objectionable content)

## Price
Free, no in-app purchases

## App Privacy (nutrition label)
Data Not Collected. The app sends the person's own tokens only to Vercel, Render and GitHub, directly from the device; the developer receives nothing.

## Notes for App Review
Deploy Center needs a Vercel access token or a Render API key to show real projects. To review every screen without one:

1. Open the app and tap "Try the demo" (or Settings → Demo mode).
2. The demo shows six made-up projects: one building, one failed, three waiting, one up to date.
3. Open a waiting project and tap "Deploy the newest commit …": a confirmation, then Face ID (or the passcode), then the deploy is simulated.
4. "Roll back …" works the same way in the demo.
5. Settings → "Notify when something waits or fails" asks for notification permission.
6. "Connect to the Mac" gets the keys from the companion Mac app, through iCloud Keychain or a QR code shown on the Mac. It needs the Mac app; the demo covers every other screen.
7. Live Activities: in the demo, deploy a waiting project and lock the phone. A Live Activity on the Lock Screen and in the Dynamic Island shows the build until the simulated deploy is live. No push service is used; it is updated only while the app runs.
8. Background App Refresh (`UIBackgroundModes: fetch`): iOS wakes the app now and then to read the project list again, so a failed build or a newly waiting project can be reported as a local notification (only when step 5 is on). Nothing is sent to a server. The same background time lets a followed deploy finish after the screen locks.
9. Quick Actions (touch and hold the app icon) and Handoff open a project; the notification action "Deploy with Face ID" only opens the app, asks the usual confirmation and then Face ID. Nothing is deployed from a notification alone.

In demo mode nothing is sent anywhere. With a real token the app talks only to api.vercel.com, api.render.com and api.github.com. There is no server of ours and no login.
