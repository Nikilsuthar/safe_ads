import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'config.dart';
import 'core.dart';
import 'safe_ads.dart';

/// Shared behaviour of banner and native widgets:
///
/// * a rebuild never requests a new ad - only a new screen visit can;
/// * a still-fresh ad from the previous visit is reused (see [AdPool]);
/// * a failed load is retried a couple of times with back-off, then rests;
/// * every request goes through the hourly request budget.
abstract class _PooledAdState<W extends StatefulWidget, T extends AdWithView> extends State<W> {
  AdFormat get format;
  AdPool<T> get pool;
  String get placementLabel;

  /// Builds the ad object. Must wire the four callbacks into its listener.
  T createAd(
    String unitId,
    AdRequest request, {
    required void Function(Ad ad) onLoaded,
    required void Function(Ad ad, LoadAdError error) onFailed,
    required void Function() onClicked,
    required void Function() onImpression,
  });

  /// Called when an ad (new or reused) is ready to be shown.
  void onReady(T ad, {required bool reused}) {}

  /// Called when a load attempt failed.
  void onLoadFailed(LoadAdError error) {}

  T? _ad;
  String? _key;
  bool _loaded = false;
  Timer? _retryTimer;
  VoidCallback? _readyListener;

  T? get ad => _ad;
  bool get isLoaded => _loaded && _ad != null;

  /// Starts (once) loading for [key]; waits for the SDK to become ready.
  void beginLoad(String key) {
    if (_key != null) return;
    _key = key;
    final core = SafeAds.maybeCore;
    if (core == null || !core.config.enabled) return;
    if (core.ready.value) {
      _start(core);
    } else {
      _readyListener = () {
        if (core.ready.value && mounted) {
          core.ready.removeListener(_readyListener!);
          _readyListener = null;
          _start(core);
        }
      };
      core.ready.addListener(_readyListener!);
    }
  }

  void _start(SafeAdsCore core) {
    final reused = pool.take(_key!, core.policy.bannerMaxAge, core.now());
    if (reused != null) {
      _ad = reused;
      setState(() => _loaded = true);
      core.log(AdEventType.reused, format, placement: placementLabel, detail: 'showing the ad from the previous visit');
      onReady(reused, reused: true);
      return;
    }
    _request(core);
  }

  void _request(SafeAdsCore core) {
    final id = core.unitId(format);
    if (id == null) return;
    final tracker = core.tracker('${format.name}:$_key');
    if (!tracker.canRequest()) {
      core.log(AdEventType.blocked, format, placement: placementLabel, detail: 'waiting for back-off/rest');
      return;
    }
    if (!core.acquireBudget(format, placementLabel)) return;

    core.log(AdEventType.request, format, placement: placementLabel);
    late T ad;
    ad = createAd(
      id,
      core.request,
      onLoaded: (_) {
        if (!mounted) {
          ad.dispose();
          return;
        }
        tracker.onSuccess();
        pool.put(_key!, ad, core.now());
        core.log(AdEventType.loaded, format, placement: placementLabel);
        setState(() => _loaded = true);
        onReady(ad, reused: false);
      },
      onFailed: (failed, error) {
        failed.dispose();
        if (identical(_ad, failed)) _ad = null;
        core.log(AdEventType.failed, format, placement: placementLabel, detail: 'code ${error.code}: ${error.message}');
        onLoadFailed(error);
        final delay = tracker.onFailure(fatal: error.code == 1);
        if (delay != null && mounted) {
          core.log(AdEventType.retryScheduled, format,
              placement: placementLabel, detail: 'retry ${tracker.failures}/${core.policy.maxLoadRetries} in ${delay.inSeconds}s');
          _retryTimer?.cancel();
          _retryTimer = Timer(delay, () {
            if (mounted && !_loaded) _request(core);
          });
        } else if (delay == null) {
          core.log(AdEventType.gaveUp, format,
              placement: placementLabel, detail: 'resting ${core.policy.giveUpCooldown.inSeconds}s; the next visit starts a new cycle');
        }
      },
      onClicked: () => core.log(AdEventType.clicked, format, placement: placementLabel),
      onImpression: () => core.log(AdEventType.impression, format, placement: placementLabel),
    );
    _ad = ad;
    ad.load();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    final core = SafeAds.maybeCore;
    if (_readyListener != null && core != null) core.ready.removeListener(_readyListener!);
    final ad = _ad;
    if (ad != null) {
      if (_loaded && _key != null) {
        pool.release(_key!, ad);
      } else {
        ad.dispose();
      }
    }
    super.dispose();
  }
}

/// Banner sizes.
enum BannerSize {
  /// Anchored adaptive banner sized to the screen width (recommended).
  adaptive,

  /// Adaptive banner that sizes its height to the ad - for use inside lists.
  inlineAdaptive,
  banner,
  largeBanner,
  mediumRectangle,
  fullBanner,
  leaderboard,
}

/// A banner ad that fails silently (renders nothing) and never blocks the UI.
///
/// ```dart
/// SafeBannerAd(placement: 'home')
/// ```
class SafeBannerAd extends StatefulWidget {
  const SafeBannerAd({
    super.key,
    this.placement,
    this.size = BannerSize.adaptive,
    this.onLoaded,
    this.onFailed,
    this.onClicked,
  });

  /// Names the screen/slot (also the reuse key). Defaults to the route name.
  final String? placement;
  final BannerSize size;

  /// Called with true when an ad is showing, false when a load failed.
  final ValueChanged<bool>? onLoaded;
  final void Function(LoadAdError error)? onFailed;
  final VoidCallback? onClicked;

  @override
  State<SafeBannerAd> createState() => _SafeBannerAdState();
}

class _SafeBannerAdState extends _PooledAdState<SafeBannerAd, BannerAd> {
  static final AdPool<BannerAd> _pool = AdPool<BannerAd>();

  AdSize? _size;
  double? _height;
  bool _begun = false;
  late String _placement;

  @override
  AdFormat get format => AdFormat.banner;
  @override
  AdPool<BannerAd> get pool => _pool;
  @override
  String get placementLabel => _placement;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_begun) return;
    final core = SafeAds.maybeCore;
    if (core == null || !core.config.enabled) return;
    _begun = true;
    _placement = widget.placement ?? ModalRoute.of(context)?.settings.name ?? 'screen';
    _resolveSize();
  }

  Future<void> _resolveSize() async {
    final width = MediaQuery.sizeOf(context).width.truncate();
    AdSize? size;
    switch (widget.size) {
      case BannerSize.adaptive:
        size = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
      case BannerSize.inlineAdaptive:
        size = AdSize.getCurrentOrientationInlineAdaptiveBannerAdSize(width);
      case BannerSize.banner:
        size = AdSize.banner;
      case BannerSize.largeBanner:
        size = AdSize.largeBanner;
      case BannerSize.mediumRectangle:
        size = AdSize.mediumRectangle;
      case BannerSize.fullBanner:
        size = AdSize.fullBanner;
      case BannerSize.leaderboard:
        size = AdSize.leaderboard;
    }
    if (size == null || !mounted) return;
    _size = size;
    beginLoad('${widget.size.name}:$_placement@${size.width}x${size.height}');
  }

  @override
  BannerAd createAd(
    String unitId,
    AdRequest request, {
    required void Function(Ad ad) onLoaded,
    required void Function(Ad ad, LoadAdError error) onFailed,
    required void Function() onClicked,
    required void Function() onImpression,
  }) {
    return BannerAd(
      adUnitId: unitId,
      size: _size!,
      request: request,
      listener: BannerAdListener(
        onAdLoaded: onLoaded,
        onAdFailedToLoad: onFailed,
        onAdClicked: (_) {
          onClicked();
          widget.onClicked?.call();
        },
        onAdImpression: (_) => onImpression(),
      ),
    );
  }

  @override
  void onReady(BannerAd ad, {required bool reused}) {
    widget.onLoaded?.call(true);
    if (widget.size == BannerSize.inlineAdaptive) {
      ad.getPlatformAdSize().then((s) {
        if (mounted && s != null) setState(() => _height = s.height.toDouble());
      });
    }
  }

  @override
  void onLoadFailed(LoadAdError error) {
    widget.onLoaded?.call(false);
    widget.onFailed?.call(error);
  }

  @override
  Widget build(BuildContext context) {
    final ad = this.ad;
    if (!isLoaded || ad == null) return const SizedBox.shrink();
    final isInline = widget.size == BannerSize.inlineAdaptive;
    final height = isInline ? (_height ?? 0) : ad.size.height.toDouble();
    if (height <= 0) return const SizedBox.shrink();
    return SizedBox(width: ad.size.width.toDouble(), height: height, child: AdWidget(ad: ad));
  }
}

/// A native ad drawn with Google's built-in template (small or medium).
///
/// ```dart
/// SafeNativeAd(placement: 'feed', template: TemplateType.medium)
/// ```
class SafeNativeAd extends StatefulWidget {
  const SafeNativeAd({
    super.key,
    this.placement = 'native',
    this.template = TemplateType.medium,
    this.style,
    this.height,
    this.onLoaded,
    this.onFailed,
    this.onClicked,
  });

  final String placement;
  final TemplateType template;

  /// Space reserved for the ad, in logical pixels (default 100 small / 360
  /// medium). Google's template draws itself at its own fixed size (about 90 dp
  /// small / 350 dp medium) pinned to the top, so a larger value only adds blank
  /// space below it.
  final double? height;

  /// Full control over colours / text styles (overrides [template]).
  final NativeTemplateStyle? style;
  final ValueChanged<bool>? onLoaded;
  final void Function(LoadAdError error)? onFailed;
  final VoidCallback? onClicked;

  @override
  State<SafeNativeAd> createState() => _SafeNativeAdState();
}

class _SafeNativeAdState extends _PooledAdState<SafeNativeAd, NativeAd> {
  static final AdPool<NativeAd> _pool = AdPool<NativeAd>();

  bool _begun = false;

  @override
  AdFormat get format => AdFormat.native;
  @override
  AdPool<NativeAd> get pool => _pool;
  @override
  String get placementLabel => widget.placement;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_begun) return;
    final core = SafeAds.maybeCore;
    if (core == null || !core.config.enabled) return;
    _begun = true;
    beginLoad('${widget.template.name}:${widget.placement}');
  }

  @override
  NativeAd createAd(
    String unitId,
    AdRequest request, {
    required void Function(Ad ad) onLoaded,
    required void Function(Ad ad, LoadAdError error) onFailed,
    required void Function() onClicked,
    required void Function() onImpression,
  }) {
    return NativeAd(
      adUnitId: unitId,
      request: request,
      nativeTemplateStyle: widget.style ?? NativeTemplateStyle(templateType: widget.template),
      listener: NativeAdListener(
        onAdLoaded: onLoaded,
        onAdFailedToLoad: onFailed,
        onAdClicked: (_) {
          onClicked();
          widget.onClicked?.call();
        },
        onAdImpression: (_) => onImpression(),
      ),
    );
  }

  @override
  void onReady(NativeAd ad, {required bool reused}) => widget.onLoaded?.call(true);

  @override
  void onLoadFailed(LoadAdError error) {
    widget.onLoaded?.call(false);
    widget.onFailed?.call(error);
  }

  @override
  Widget build(BuildContext context) {
    final ad = this.ad;
    if (!isLoaded || ad == null) return const SizedBox.shrink();
    final small = (widget.style?.templateType ?? widget.template) == TemplateType.small;
    return SizedBox(
      width: double.infinity,
      height: widget.height ?? (small ? 100 : 360),
      child: AdWidget(ad: ad),
    );
  }
}
