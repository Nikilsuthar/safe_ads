import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// The ad formats AdMob offers.
enum AdFormat {
  banner,
  native,
  interstitial,
  rewarded,
  rewardedInterstitial,
  appOpen
}

/// Your AdMob ad unit ids. Pass only the formats you use; the rest stay null
/// and are simply never requested.
class AdIds {
  const AdIds({
    this.banner,
    this.native,
    this.interstitial,
    this.rewarded,
    this.rewardedInterstitial,
    this.appOpen,
  });

  final String? banner;
  final String? native;
  final String? interstitial;
  final String? rewarded;
  final String? rewardedInterstitial;
  final String? appOpen;

  String? forFormat(AdFormat format) {
    switch (format) {
      case AdFormat.banner:
        return banner;
      case AdFormat.native:
        return native;
      case AdFormat.interstitial:
        return interstitial;
      case AdFormat.rewarded:
        return rewarded;
      case AdFormat.rewardedInterstitial:
        return rewardedInterstitial;
      case AdFormat.appOpen:
        return appOpen;
    }
  }

  /// Google's public **test** ad units. They always serve test creatives, so
  /// tapping them can never harm your account.
  static AdIds testIds([TargetPlatform? platform]) {
    final ios = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
    return ios
        ? const AdIds(
            banner: 'ca-app-pub-3940256099942544/2435281174',
            native: 'ca-app-pub-3940256099942544/3986624511',
            interstitial: 'ca-app-pub-3940256099942544/4411468910',
            rewarded: 'ca-app-pub-3940256099942544/1712485313',
            rewardedInterstitial: 'ca-app-pub-3940256099942544/6978759866',
            appOpen: 'ca-app-pub-3940256099942544/5575463023',
          )
        : const AdIds(
            banner: 'ca-app-pub-3940256099942544/9214589741',
            native: 'ca-app-pub-3940256099942544/2247696110',
            interstitial: 'ca-app-pub-3940256099942544/1033173712',
            rewarded: 'ca-app-pub-3940256099942544/5224354917',
            rewardedInterstitial: 'ca-app-pub-3940256099942544/5354046379',
            appOpen: 'ca-app-pub-3940256099942544/9257395921',
          );
  }
}

/// The safety rules. The defaults are deliberately conservative so a new app
/// never hammers AdMob (which protects match rate and account standing).
class AdPolicy {
  const AdPolicy({
    this.maxLoadRetries = 2,
    this.retryBackoff = const Duration(seconds: 30),
    this.giveUpCooldown = const Duration(minutes: 2),
    this.maxRequestsPerHour = 120,
    this.interstitialCooldown = const Duration(minutes: 2),
    this.launchGrace = const Duration(seconds: 45),
    this.minActionsBetweenInterstitials = 2,
    this.maxInterstitialsPerSession = 10,
    this.bannerMaxAge = const Duration(minutes: 5),
    this.fullScreenMaxAge = const Duration(minutes: 55),
    this.appOpenMinInterval = const Duration(minutes: 5),
    this.appOpenMinBackground = const Duration(seconds: 30),
    this.appOpenMaxAge = const Duration(hours: 3, minutes: 30),
  });

  /// Extra attempts after the first failed load (so a "cycle" is 1 + this many
  /// requests, default 3). Never more - then the slot rests for [giveUpCooldown].
  final int maxLoadRetries;

  /// Wait before retry n is `retryBackoff * n` (30 s, then 60 s).
  final Duration retryBackoff;

  /// After a cycle fails completely, no new request is made for this long. A
  /// later screen visit / user action then starts a fresh cycle.
  final Duration giveUpCooldown;

  /// Hard cap on ad requests per rolling hour across all formats.
  final int maxRequestsPerHour;

  /// Minimum time between two interstitials.
  final Duration interstitialCooldown;

  /// No interstitial during the first seconds after app start.
  final Duration launchGrace;

  /// Completed user actions required between two interstitials.
  final int minActionsBetweenInterstitials;

  /// Interstitials per app session (process lifetime).
  final int maxInterstitialsPerSession;

  /// A loaded banner/native ad is reused on a later screen visit until it is
  /// this old.
  final Duration bannerMaxAge;

  /// Loaded interstitial / rewarded ads expire (AdMob: ~1 h); discard earlier.
  final Duration fullScreenMaxAge;

  /// Minimum gap between two app-open ads.
  final Duration appOpenMinInterval;

  /// The app must have been in the background at least this long before an
  /// app-open ad may show (avoids ads after permission dialogs / share sheets).
  final Duration appOpenMinBackground;

  /// App-open ads expire after 4 h on AdMob's side.
  final Duration appOpenMaxAge;
}

/// How user consent (GDPR/UMP) is handled.
enum ConsentMode {
  /// Show Google's consent form where the law requires it (recommended).
  umpIfRequired,

  /// Skip consent handling (only if you handle consent yourself).
  none,
}

class SafeAdsConfig {
  const SafeAdsConfig({
    required this.ids,
    this.useTestIds = false,
    this.policy = const AdPolicy(),
    this.consent = ConsentMode.umpIfRequired,
    this.enabled = true,
    this.testDeviceIds = const [],
    this.requestConfiguration,
    this.request = const AdRequest(),
    this.autoPreload = const {AdFormat.interstitial},
    this.appOpenEnabled = false,
    this.persistState = true,
    this.logToConsole = kDebugMode,
    this.onEvent,
  });

  /// Your ad unit ids.
  final AdIds ids;

  /// Replace every id with Google's test ids (use in debug / closed testing).
  final bool useTestIds;

  final AdPolicy policy;
  final ConsentMode consent;

  /// Master switch. When false nothing is initialised or requested and every
  /// call completes immediately as "skipped".
  final bool enabled;

  /// Devices that always receive test ads (add your own phone's id here to be
  /// able to use the real app without risking invalid clicks).
  final List<String> testDeviceIds;

  /// Content rating / child-directed tags, etc.
  final RequestConfiguration? requestConfiguration;

  /// Base request (keywords, non-personalised flag, ...).
  final AdRequest request;

  /// Formats loaded in advance once the SDK is ready. Rewarded and app-open
  /// are normally prepared by the screen that needs them (`SafeAds.preload`).
  final Set<AdFormat> autoPreload;

  /// Show an app-open ad when the app returns from the background.
  final bool appOpenEnabled;

  /// Persist interstitial counters/timestamps across app launches.
  final bool persistState;

  final bool logToConsole;

  /// Receives every ad event (for your own analytics).
  final void Function(AdEvent event)? onEvent;
}

enum AdEventType {
  request,
  loaded,
  failed,
  retryScheduled,
  gaveUp,
  blocked,
  shown,
  dismissed,
  clicked,
  impression,
  reward,
  skipped,
  reused,
  info,
}

class AdEvent {
  AdEvent(this.type, this.format, {this.placement, this.detail})
      : time = DateTime.now();

  final AdEventType type;

  /// Null for events that are not tied to one format (SDK / consent).
  final AdFormat? format;
  final String? placement;
  final String? detail;
  final DateTime time;

  @override
  String toString() =>
      '[SafeAds] ${type.name.padRight(14)} ${format?.name ?? 'sdk'}${placement != null ? ' @${placement!}' : ''}'
      '${detail != null ? ' - ${detail!}' : ''}';
}

/// Why a show request did not display an ad.
enum AdSkipReason {
  disabled,
  noAdUnit,
  notReady,
  alreadyShowing,
  launchGrace,
  cooldown,
  notEnoughActions,
  sessionCap,
}

class AdResult {
  const AdResult._(this.shown, this.skipReason, this.rewarded, this.error);

  /// An ad was displayed and has now been closed.
  final bool shown;
  final AdSkipReason? skipReason;

  /// Rewarded formats: the user earned the reward.
  final bool rewarded;

  /// The ad failed while showing (rare).
  final String? error;

  const AdResult.shown({bool rewarded = false})
      : this._(true, null, rewarded, null);
  const AdResult.skipped(AdSkipReason reason)
      : this._(false, reason, false, null);
  const AdResult.failed(String error) : this._(false, null, false, error);

  @override
  String toString() => shown
      ? 'AdResult(shown${rewarded ? ', rewarded' : ''})'
      : 'AdResult(skipped: ${skipReason?.name ?? error})';
}
