# safe_ads

One safe, reusable AdMob layer for Flutter. Add it to any app, pass your ad unit
ids, and call a few functions. All the risky parts (consent, retries, request
rates, cooldowns, re-requests on navigation) are handled inside, with
conservative defaults, so you cannot flood AdMob by accident.

Supports every AdMob format: **banner** (adaptive, inline adaptive, fixed
sizes), **native** (Google templates), **interstitial**, **rewarded**,
**rewarded interstitial** and **app open**. Android and iOS.

> Unofficial wrapper around [`google_mobile_ads`](https://pub.dev/packages/google_mobile_ads). Not affiliated with or
> endorsed by Google. You still need your own AdMob account and must follow the
> [AdMob program policies](https://support.google.com/admob/answer/6128543).

## Install

```yaml
dependencies:
  safe_ads: ^0.1.0
```

(Before it is on pub.dev you can use the git form:
`safe_ads: {git: {url: https://github.com/Nikilsuthar/safe_ads.git, ref: v0.1.0}}`.)

Android: add your **AdMob app id** to `AndroidManifest.xml` (inside
`<application>`; Google's test id shown):

```xml
<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID"
           android:value="ca-app-pub-3940256099942544~3347511713"/>
```

Android: keep the `INTERNET` permission (added by the example). Use `minSdk` 23 or higher
(`google_mobile_ads` requires it; 24+ is recommended).

### iOS setup (one time, in the app that uses the package)

Add to `ios/Runner/Info.plist` (replace with your iOS **AdMob app id**; Google's test id shown):

```xml
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-3940256099942544~1458002511</string>
<key>SKAdNetworkItems</key>
<array>
  <dict><key>SKAdNetworkIdentifier</key><string>cstr6suwn9.skadnetwork</string></dict>
</array>
```

Google lists the full SKAdNetwork id list in its
[iOS quick start](https://developers.google.com/admob/ios/quick-start#update_your_infoplist). Use iOS 13 or newer.
If your app tracks users across apps, also add `NSUserTrackingUsageDescription` and request App Tracking
Transparency before `SafeAds.init`. The consent (UMP) form is handled by the package.

> Tested on Android with Google test ads. iOS uses the same Dart code and Google's iOS test ad units, but it has
> not been run on a device by the author.

## Quick start

```dart
import 'package:safe_ads/safe_ads.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SafeAds.init(const SafeAdsConfig(
    ids: AdIds(
      banner: 'ca-app-pub-XXXX/1111111111',
      interstitial: 'ca-app-pub-XXXX/2222222222',
      rewarded: 'ca-app-pub-XXXX/3333333333',
    ),
    useTestIds: kDebugMode,          // Google test ads while developing
    autoPreload: {AdFormat.interstitial},
  ));
  runApp(const MyApp());
}
```

`init` returns immediately. Consent (UMP) and SDK start-up run in the
background; `SafeAds.ready` becomes true when ads may be requested. Nothing
blocks your UI.

### Banner / native (widgets)

```dart
SafeBannerAd(placement: 'home')                       // adaptive, reused on return
SafeBannerAd(size: BannerSize.mediumRectangle)
SafeNativeAd(placement: 'feed', template: TemplateType.medium)   // reserves 360 dp (small: 100)
```

Keep a native ad completely visible (not under a bottom bar or partly scrolled
off screen). In debug builds Google shows a "native ad validator" banner.
Known limitation: Google's built-in *medium* template has a fixed height, and
for a creative with a 3-line description the validator can report "1
implementation issue: advertiser assets outside native ad view" (the install
button is touching the frame edge). It is cosmetic in test creatives; for full
control of a native layout, build your own `NativeAd` with a platform factory.

They render nothing until an ad is loaded and never throw. Rebuilding never
requests a new ad. Returning to a screen shows the previous ad again (up to
5 minutes old) instead of requesting a new one.

### Interstitial

```dart
await SafeAds.registerAction();                       // user completed something
await SafeAds.showInterstitial(
  placement: 'saved',
  onFinished: () => goToNextScreen(),                 // ALWAYS runs exactly once
);
```

`onFinished` runs after the ad is closed, or immediately when no ad was shown
(not enough actions, cooldown, not loaded...). Put your navigation there.
`onShown` / `onClosed` are also available. The returned `AdResult` tells you
whether it was shown and, if not, why (`skipReason`).

### Rewarded / rewarded interstitial / app open

```dart
await SafeAds.showRewarded(
  placement: 'extra_hint',
  onReward: (reward) => giveHint(reward.amount),
  onNotAvailable: () => toast('Ad not ready, try again in a moment'),
  onFinished: () => refreshUi(),
);

SafeAds.preload(AdFormat.rewarded);                   // warm one up on a screen
SafeAds.isReady(AdFormat.rewarded);                   // bool for enabling a button

// App open: automatic when SafeAdsConfig(appOpenEnabled: true, ...)
SafeAds.suppressAppOpenFor(const Duration(seconds: 20)); // around a permission dialog
```

### Consent / privacy options

Consent is shown automatically where the law requires it. Add an entry in your
settings screen:

```dart
ValueListenableBuilder<bool>(
  valueListenable: SafeAds.privacyOptionsRequired,
  builder: (_, required, __) =>
      required ? ListTile(title: const Text('Ad privacy options'), onTap: SafeAds.showPrivacyOptions) : const SizedBox(),
)
```

## The safety rules (all configurable via `AdPolicy`)

| Rule | Default |
|------|---------|
| Load attempts per failed cycle | 1 request + **2 retries** (after 30 s, then 60 s) = 3, never more |
| After a failed cycle | the slot **rests 2 min**; the next screen visit / user action then starts a fresh cycle |
| Invalid request (e.g. wrong ad unit id) | no retries, rests 10 min |
| Hard cap | **120 requests per hour** across all formats |
| Banner / native | reused for **5 min** on the next visit; never in two places at once; one request per visit at most |
| Interstitial | only after **2 completed actions**, **2 min** cooldown, **45 s** after launch, max 10 per session, only one on screen |
| Loaded full-screen ads | discarded after 55 min (AdMob expires them after ~1 h) |
| App open | off by default; needs 30 s in background, 5 min between ads, never right after another full-screen ad |
| Counters | survive restarts (shared_preferences) |

A failed ad request never throws and never blocks your app.

## Checking that everything works

```dart
SafeAds.stats.summary();     // requests / loaded / failed / shown / reused per format
SafeAds.events.listen(...);  // every event as it happens
SafeAds.recentEvents;        // last 300 events (for a debug screen)
```

With `logToConsole` (default in debug) every event is printed as
`[SafeAds] request  banner @home`, `[SafeAds] failed ... code 3: No fill`,
`[SafeAds] retryScheduled ... retry 1/2 in 30s`, `[SafeAds] gaveUp ...`, etc.
Filter logcat with `adb logcat -s flutter | grep SafeAds`.

`example/` is a test bench that exercises every format with Google's test ads.

## Staying safe with your AdMob account

* Use `useTestIds: true` (or `testDeviceIds`) whenever you or testers use the
  app. **Never tap your own real ads.**
* Don't show interstitials on launch, exit, or in the middle of a task.
* Keep banners away from tappable controls.
* Declare ads, the Advertising ID and the data AdMob collects in Play Console.

## Develop

```
flutter test         # safety-rule unit tests
cd example && flutter run
```
