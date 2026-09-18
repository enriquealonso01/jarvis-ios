# BUILD (Enrique's manual ritual)

You only ever do these steps. Everything else is agent-deployed.

## One-time (per Mac)
1. `git clone https://github.com/enriquealonso01/jarvis-ios.git` (private repo — private-repo clone is pushed and live)
2. `cd jarvis-ios/ios && xcodegen` (XcodeGen: `brew install xcodegen`) — generates JarvisApp.xcodeproj from project.yml
3. Open `ios/JarvisApp.xcodeproj`
4. Signing & Capabilities: select your Personal Team (the one tied to your Apple Developer sub)
5. Product > Scheme > JarvisApp; destination: any iPhone

## Every update cycle (agents tell you when via WhatsApp DM)
1. `git pull`
2. In Xcode: Product > Archive
3. Window > Organizer > Distribute App > TestFlight (internal)
4. TestFlight app on phone: update, install

## First TestFlight setup
- App Store Connect > My Apps > + > New App (iOS, name "JARVIS", bundle id
  com.enriquecodes.jarvis, SKU jarvis-ios-001). TestFlight tab > Internal Testing >
  add yourself. Subsequent archives just need upload; testers persist.

## Notes
- TestFlight builds expire after 90 days — the loop agent will remind you well ahead.
- No App Review is involved for internal testers (up to 100 devices).
