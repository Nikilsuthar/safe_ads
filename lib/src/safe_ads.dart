import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'config.dart';
import 'consent.dart';
import 'core.dart';
import 'full_screen.dart';
import 'guards.dart';
import 'prefs_storage.dart';

/// The single entry point to all ads.
///
/// ```dart
/// await SafeAds.init(SafeAdsConfig(
///   ids: AdIds(banner: '...', interstitial: '...'),
///   useTestIds: kDebugMode,
/// ));
///
/// // after the user finished something:
/// await SafeAds.registerAction();
/// await SafeAds.showInterstitial(placement: 'saved', onFinished: goNext);
/// ```
///
/// Everything is rate-limited and capped inside; calling these methods from
/// anywhere, as often as you like, cannot flood AdMob.
class SafeAds {
  SafeAds._();

  static SafeAdsCore? _core;
  static final ValueNotifier<bool> _ready = ValueNotifier(false);
  static final ValueNotifier<bool> _privacy = ValueNotifier(false);
  static FullScreenSlot<InterstitialAd>? _interstitial;
  static FullScreenSlot<RewardedAd>? _rewarded;
  static FullScreenSlot<RewardedInterstitialAd>? _rewardedInterstitial;
  static FullScreenSlot<AppOpenAd>? _appOpen;
  static _AppOpenObserver? _observer;

  /// Internal. The running core, or null before [init] / when disabled.
  static SafeAdsCore? get maybeCore => _core;

  static bool get isInitialized => _core != null;

  /// True once consent allows ads and the SDK is initialised.
  static ValueListenable<bool> get ready => _ready;

  /// True where you must offer a "Privacy options" entry (e.g. in Settings).
  static ValueListenable<bool> get privacyOptionsRequired => _privacy;

  /// Live stream of every ad event (requests, loads, failures, shows, ...).
  static Stream<AdEvent> get events => _core?.events ?? const Stream.empty();

  /// The last events, newest last (for an in-app debug screen).
  static List<AdEvent> get recentEvents => List.unmodifiable(_core?.recentEvents ?? const <AdEvent>[]);

  static AdStats get stats => _core?.stats ?? AdStats();

  /// Starts SafeAds. Returns quickly: consent and SDK start-up continue in the
  /// background and [ready] flips to true when ads may be requested.
  static Future<void> init(SafeAdsConfig config) async {
    if (_core != null) return;
    final core = SafeAdsCore(config, readyNotifier: _ready, privacyNotifier: _privacy);
    _core = core;

    AdStorage storage = MemoryAdStorage();
    if (config.persistState) {
      try {
        storage = await SharedPrefsAdStorage.create();
      } catch (_) {
        // Fall back to in-memory counters.
      }
    }
    core.gate = InterstitialGate(policy: config.policy, storage: storage);

    if (!config.enabled) {
      core.log(AdEventType.info, null, detail: 'disabled by config - no ads will be requested');
      return;
    }
    core.log(AdEventType.info, null, detail: 'init (testIds=${config.useTestIds})');
    unawaited(_start(core));
  }

  static Future<void> _start(SafeAdsCore core) async {
    try {
      var allowed = true;
      if (core.config.consent == ConsentMode.umpIfRequired) {
        allowed = await ConsentManager.gather();
        core.privacyOptionsRequired.value = await ConsentManager.privacyOptionsRequired();
      }
      if (!allowed) {
        core.log(AdEventType.info, null, detail: 'consent does not allow ads (yet)');
        return;
      }
      await _initSdk(core);
    } catch (e) {
      core.log(AdEventType.failed, null, detail: 'start-up failed: $e');
    }
  }

  static Future<void> _initSdk(SafeAdsCore core) async {
    if (core.ready.value) return;
    final cfg = core.config;
    if (cfg.requestConfiguration != null || cfg.testDeviceIds.isNotEmpty) {
      final rc = cfg.requestConfiguration;
      await MobileAds.instance.updateRequestConfiguration(RequestConfiguration(
        maxAdContentRating: rc?.maxAdContentRating,
        tagForChildDirectedTreatment: rc?.tagForChildDirectedTreatment,
        tagForUnderAgeOfConsent: rc?.tagForUnderAgeOfConsent,
        testDeviceIds: [...?rc?.testDeviceIds, ...cfg.testDeviceIds],
      ));
    }
    await MobileAds.instance.initialize();
    _buildSlots(core);
    core.ready.value = true;
    core.log(AdEventType.info, null, detail: 'SDK ready');
    for (final f in cfg.autoPreload) {
      preload(f);
    }
    if (cfg.appOpenEnabled && core.unitId(AdFormat.appOpen) != null) {
      preload(AdFormat.appOpen);
      _observer ??= _AppOpenObserver(core)..attach();
    }
  }

  /// Opens Google's "Privacy options" form. Call from a settings entry shown
  /// when [privacyOptionsRequired] is true.
  static Future<void> showPrivacyOptions() async {
    final core = _core;
    if (core == null || !core.config.enabled) return;
    final allowed = await ConsentManager.showPrivacyOptions();
    if (allowed && !core.ready.value) await _initSdk(core);
  }

  // ---------------------------------------------------------------------------
  // Preloading / state
  // ---------------------------------------------------------------------------

  /// Loads a full-screen format in advance (interstitial, rewarded, rewarded
  /// interstitial, app open). Cheap and safe to call repeatedly.
  static void preload(AdFormat format) {
    switch (format) {
      case AdFormat.interstitial:
        _interstitial?.ensureLoaded(reason: 'preload');
      case AdFormat.rewarded:
        _rewarded?.ensureLoaded(reason: 'preload');
      case AdFormat.rewardedInterstitial:
        _rewardedInterstitial?.ensureLoaded(reason: 'preload');
      case AdFormat.appOpen:
        _appOpen?.ensureLoaded(reason: 'preload');
      case AdFormat.banner:
      case AdFormat.native:
        break; // loaded by their widgets
    }
  }

  /// Whether a full-screen ad of this format is loaded and ready to show.
  static bool isReady(AdFormat format) {
    switch (format) {
      case AdFormat.interstitial:
        return _interstitial?.isReady ?? false;
      case AdFormat.rewarded:
        return _rewarded?.isReady ?? false;
      case AdFormat.rewardedInterstitial:
        return _rewardedInterstitial?.isReady ?? false;
      case AdFormat.appOpen:
        return _appOpen?.isReady ?? false;
      case AdFormat.banner:
      case AdFormat.native:
        return false;
    }
  }

  /// Counts one completed user action towards the interstitial rule
  /// ("an interstitial only after N completed actions").
  static Future<void> registerAction() async {
    final core = _core;
    if (core == null || !core.config.enabled) return;
    await core.gate.registerAction();
    // Keep the next ad warm for the moment the rule is satisfied.
    _interstitial?.ensureLoaded(reason: 'action');
  }

  /// Stops app-open ads for a while (e.g. around a permission dialog).
  static void suppressAppOpenFor(Duration duration) {
    final core = _core;
    if (core != null) core.appOpenSuppressedUntil = core.now().add(duration);
  }

  // ---------------------------------------------------------------------------
  // Show
  // ---------------------------------------------------------------------------

  /// Shows an interstitial **if the rules allow it** (launch grace, cooldown,
  /// enough completed actions, session cap, an ad is ready). Otherwise it does
  /// nothing. Either way [onFinished] runs exactly once - right after the ad is
  /// closed, or immediately when nothing was shown - so navigation can simply
  /// continue from there.
  static Future<AdResult> showInterstitial({
    String placement = 'default',
    int? minActions,
    VoidCallback? onShown,
    VoidCallback? onClosed,
    VoidCallback? onFinished,
  }) {
    return _guarded(AdFormat.interstitial, placement, onFinished, (core, finish) async {
      final slot = _interstitial;
      if (slot == null) return const AdResult.skipped(AdSkipReason.noAdUnit);
      if (core.fullScreenShowing || _justDismissed(core)) {
        return const AdResult.skipped(AdSkipReason.alreadyShowing);
      }
      final reason = core.gate.check(minActions: minActions);
      if (reason != null) return AdResult.skipped(reason);
      return _present<InterstitialAd>(
        core,
        slot,
        AdFormat.interstitial,
        placement,
        onShown: () {
          unawaited(core.gate.markShown());
          onShown?.call();
        },
        onClosed: onClosed,
      );
    });
  }

  /// Shows a rewarded ad (the user chose to watch it). [onReward] runs when the
  /// reward was earned; [onNotAvailable] when no ad is ready (a load is started
  /// for next time). [onFinished] always runs exactly once at the end.
  static Future<AdResult> showRewarded({
    String placement = 'default',
    required void Function(RewardItem reward) onReward,
    VoidCallback? onShown,
    VoidCallback? onClosed,
    VoidCallback? onNotAvailable,
    VoidCallback? onFinished,
  }) {
    return _guarded(AdFormat.rewarded, placement, onFinished, (core, finish) async {
      final slot = _rewarded;
      if (slot == null) return const AdResult.skipped(AdSkipReason.noAdUnit);
      if (core.fullScreenShowing) return const AdResult.skipped(AdSkipReason.alreadyShowing);
      final result = await _present<RewardedAd>(core, slot, AdFormat.rewarded, placement,
          onShown: onShown, onClosed: onClosed, onReward: onReward);
      if (result.skipReason == AdSkipReason.notReady) onNotAvailable?.call();
      return result;
    });
  }

  /// Same as [showRewarded] for the rewarded-interstitial format.
  static Future<AdResult> showRewardedInterstitial({
    String placement = 'default',
    required void Function(RewardItem reward) onReward,
    VoidCallback? onShown,
    VoidCallback? onClosed,
    VoidCallback? onNotAvailable,
    VoidCallback? onFinished,
  }) {
    return _guarded(AdFormat.rewardedInterstitial, placement, onFinished, (core, finish) async {
      final slot = _rewardedInterstitial;
      if (slot == null) return const AdResult.skipped(AdSkipReason.noAdUnit);
      if (core.fullScreenShowing) return const AdResult.skipped(AdSkipReason.alreadyShowing);
      final result = await _present<RewardedInterstitialAd>(
          core, slot, AdFormat.rewardedInterstitial, placement,
          onShown: onShown, onClosed: onClosed, onReward: onReward);
      if (result.skipReason == AdSkipReason.notReady) onNotAvailable?.call();
      return result;
    });
  }

  /// Shows an app-open ad now if one is ready and the minimum interval has
  /// passed. (Automatic when [SafeAdsConfig.appOpenEnabled] is true.)
  static Future<AdResult> showAppOpen({
    String placement = 'manual',
    VoidCallback? onClosed,
    VoidCallback? onFinished,
  }) {
    return _guarded(AdFormat.appOpen, placement, onFinished, (core, finish) async {
      final slot = _appOpen;
      if (slot == null) return const AdResult.skipped(AdSkipReason.noAdUnit);
      if (core.fullScreenShowing || _justDismissed(core)) {
        return const AdResult.skipped(AdSkipReason.alreadyShowing);
      }
      final last = _lastAppOpenShownAt;
      if (last != null && core.now().difference(last) < core.policy.appOpenMinInterval) {
        return const AdResult.skipped(AdSkipReason.cooldown);
      }
      return _present<AppOpenAd>(core, slot, AdFormat.appOpen, placement,
          onShown: () => _lastAppOpenShownAt = core.now(), onClosed: onClosed);
    });
  }

  static DateTime? _lastAppOpenShownAt;

  static bool _justDismissed(SafeAdsCore core) {
    final at = core.lastFullScreenDismissedAt;
    return at != null && core.now().difference(at) < const Duration(seconds: 3);
  }

  /// Runs [body], guarantees [onFinished] is called exactly once, logs skips,
  /// and turns "SafeAds not started / disabled" into a plain skipped result.
  static Future<AdResult> _guarded(
    AdFormat format,
    String placement,
    VoidCallback? onFinished,
    Future<AdResult> Function(SafeAdsCore core, void Function() finish) body,
  ) async {
    var finished = false;
    void finish() {
      if (finished) return;
      finished = true;
      onFinished?.call();
    }

    final core = _core;
    try {
      if (core == null || !core.config.enabled) return const AdResult.skipped(AdSkipReason.disabled);
      if (!core.canRequest) {
        core.log(AdEventType.skipped, format, placement: placement, detail: 'SDK not ready yet');
        return const AdResult.skipped(AdSkipReason.notReady);
      }
      final result = await body(core, finish);
      if (!result.shown) {
        core.log(AdEventType.skipped, format,
            placement: placement, detail: result.skipReason?.name ?? result.error);
      }
      return result;
    } finally {
      finish();
    }
  }

  static Future<AdResult> _present<T>(
    SafeAdsCore core,
    FullScreenSlot<T> slot,
    AdFormat format,
    String placement, {
    VoidCallback? onShown,
    VoidCallback? onClosed,
    void Function(RewardItem reward)? onReward,
  }) async {
    final ad = slot.take();
    if (ad == null) {
      slot.ensureLoaded(reason: 'show-miss');
      return const AdResult.skipped(AdSkipReason.notReady);
    }

    core.fullScreenShowing = true;
    final done = Completer<AdResult>();
    var rewarded = false;

    void leave() {
      slot.disposeAd(ad);
      core.fullScreenShowing = false;
      core.lastFullScreenDismissedAt = core.now();
      slot.ensureLoaded(reason: 'after-show');
    }

    try {
      await slot.present(
        ad,
        ShowCallbacks(
          onShown: () {
            core.log(AdEventType.shown, format, placement: placement);
            onShown?.call();
          },
          onImpression: () => core.log(AdEventType.impression, format, placement: placement),
          onClicked: () => core.log(AdEventType.clicked, format, placement: placement),
          onReward: onReward == null
              ? null
              : (reward) {
                  rewarded = true;
                  core.log(AdEventType.reward, format,
                      placement: placement, detail: '${reward.amount} ${reward.type}');
                  onReward(reward);
                },
          onDismissed: () {
            leave();
            core.log(AdEventType.dismissed, format, placement: placement);
            onClosed?.call();
            if (!done.isCompleted) done.complete(AdResult.shown(rewarded: rewarded));
          },
          onFailed: (error) {
            leave();
            core.log(AdEventType.failed, format,
                placement: placement, detail: 'failed to show: ${error.message}');
            if (!done.isCompleted) done.complete(AdResult.failed(error.message));
          },
        ),
      );
    } catch (e) {
      leave();
      if (!done.isCompleted) done.complete(AdResult.failed('$e'));
    }
    return done.future;
  }

  // ---------------------------------------------------------------------------
  // Slots (one per full-screen format)
  // ---------------------------------------------------------------------------

  static void _buildSlots(SafeAdsCore core) {
    final policy = core.policy;

    _interstitial = core.unitId(AdFormat.interstitial) == null
        ? null
        : FullScreenSlot<InterstitialAd>(
            core: core,
            format: AdFormat.interstitial,
            maxAge: policy.fullScreenMaxAge,
            load: (id, request, ok, fail) => InterstitialAd.load(
              adUnitId: id,
              request: request,
              adLoadCallback: InterstitialAdLoadCallback(onAdLoaded: ok, onAdFailedToLoad: fail),
            ),
            present: (ad, cb) {
              ad.fullScreenContentCallback = FullScreenContentCallback<InterstitialAd>(
                onAdShowedFullScreenContent: (_) => cb.onShown(),
                onAdDismissedFullScreenContent: (_) => cb.onDismissed(),
                onAdFailedToShowFullScreenContent: (_, e) => cb.onFailed(e),
                onAdClicked: (_) => cb.onClicked(),
                onAdImpression: (_) => cb.onImpression(),
              );
              return ad.show();
            },
            disposeAd: (ad) => ad.dispose(),
          );

    _rewarded = core.unitId(AdFormat.rewarded) == null
        ? null
        : FullScreenSlot<RewardedAd>(
            core: core,
            format: AdFormat.rewarded,
            maxAge: policy.fullScreenMaxAge,
            load: (id, request, ok, fail) => RewardedAd.load(
              adUnitId: id,
              request: request,
              rewardedAdLoadCallback: RewardedAdLoadCallback(onAdLoaded: ok, onAdFailedToLoad: fail),
            ),
            present: (ad, cb) {
              ad.fullScreenContentCallback = FullScreenContentCallback<RewardedAd>(
                onAdShowedFullScreenContent: (_) => cb.onShown(),
                onAdDismissedFullScreenContent: (_) => cb.onDismissed(),
                onAdFailedToShowFullScreenContent: (_, e) => cb.onFailed(e),
                onAdClicked: (_) => cb.onClicked(),
                onAdImpression: (_) => cb.onImpression(),
              );
              return ad.show(onUserEarnedReward: (_, reward) => cb.onReward?.call(reward));
            },
            disposeAd: (ad) => ad.dispose(),
          );

    _rewardedInterstitial = core.unitId(AdFormat.rewardedInterstitial) == null
        ? null
        : FullScreenSlot<RewardedInterstitialAd>(
            core: core,
            format: AdFormat.rewardedInterstitial,
            maxAge: policy.fullScreenMaxAge,
            load: (id, request, ok, fail) => RewardedInterstitialAd.load(
              adUnitId: id,
              request: request,
              rewardedInterstitialAdLoadCallback:
                  RewardedInterstitialAdLoadCallback(onAdLoaded: ok, onAdFailedToLoad: fail),
            ),
            present: (ad, cb) {
              ad.fullScreenContentCallback = FullScreenContentCallback<RewardedInterstitialAd>(
                onAdShowedFullScreenContent: (_) => cb.onShown(),
                onAdDismissedFullScreenContent: (_) => cb.onDismissed(),
                onAdFailedToShowFullScreenContent: (_, e) => cb.onFailed(e),
                onAdClicked: (_) => cb.onClicked(),
                onAdImpression: (_) => cb.onImpression(),
              );
              return ad.show(onUserEarnedReward: (_, reward) => cb.onReward?.call(reward));
            },
            disposeAd: (ad) => ad.dispose(),
          );

    _appOpen = core.unitId(AdFormat.appOpen) == null
        ? null
        : FullScreenSlot<AppOpenAd>(
            core: core,
            format: AdFormat.appOpen,
            maxAge: policy.appOpenMaxAge,
            load: (id, request, ok, fail) => AppOpenAd.load(
              adUnitId: id,
              request: request,
              adLoadCallback: AppOpenAdLoadCallback(onAdLoaded: ok, onAdFailedToLoad: fail),
            ),
            present: (ad, cb) {
              ad.fullScreenContentCallback = FullScreenContentCallback<AppOpenAd>(
                onAdShowedFullScreenContent: (_) => cb.onShown(),
                onAdDismissedFullScreenContent: (_) => cb.onDismissed(),
                onAdFailedToShowFullScreenContent: (_, e) => cb.onFailed(e),
                onAdClicked: (_) => cb.onClicked(),
                onAdImpression: (_) => cb.onImpression(),
              );
              return ad.show();
            },
            disposeAd: (ad) => ad.dispose(),
          );
  }
}

/// Shows an app-open ad when the app comes back from the background - only
/// after a long-enough absence, never right after another full-screen ad or
/// permission dialog, and never more often than the policy's minimum interval.
class _AppOpenObserver with WidgetsBindingObserver {
  _AppOpenObserver(this.core);

  final SafeAdsCore core;
  DateTime? _pausedAt;

  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = core.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;

    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null || core.fullScreenShowing) return;
    final suppressed = core.appOpenSuppressedUntil;
    if (suppressed != null && core.now().isBefore(suppressed)) return;
    if (core.now().difference(pausedAt) < core.policy.appOpenMinBackground) return;
    if (core.now().difference(core.gate.startedAt) < core.policy.launchGrace) return;

    SafeAds._appOpen?.ensureLoaded(reason: 'resume');
    unawaited(SafeAds.showAppOpen(placement: 'resume'));
  }
}
