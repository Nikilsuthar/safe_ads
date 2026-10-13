import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'config.dart';
import 'core.dart';

/// Callbacks the slot hands to the format-specific `present` function.
class ShowCallbacks {
  ShowCallbacks({
    required this.onShown,
    required this.onDismissed,
    required this.onFailed,
    required this.onClicked,
    required this.onImpression,
    this.onReward,
  });

  final void Function() onShown;
  final void Function() onDismissed;
  final void Function(AdError error) onFailed;
  final void Function() onClicked;
  final void Function() onImpression;
  final void Function(RewardItem reward)? onReward;
}

/// One preloaded full-screen ad (interstitial / rewarded / rewarded
/// interstitial / app open).
///
/// It loads at most one ad at a time, obeys the request budget and the retry
/// policy (a few automatic retries with growing back-off, then a rest), and
/// throws away ads that grew too old.
class FullScreenSlot<T> {
  FullScreenSlot({
    required this.core,
    required this.format,
    required this.maxAge,
    required this.load,
    required this.present,
    required this.disposeAd,
  });

  final SafeAdsCore core;
  final AdFormat format;
  final Duration maxAge;
  final void Function(String unitId, AdRequest request, void Function(T ad) onLoaded,
      void Function(LoadAdError error) onFailed) load;
  final Future<void> Function(T ad, ShowCallbacks callbacks) present;
  final void Function(T ad) disposeAd;

  T? _ad;
  DateTime? _loadedAt;
  bool _loading = false;
  Timer? _timer;

  bool get isLoading => _loading;

  bool get isReady {
    if (_ad == null) return false;
    if (core.now().difference(_loadedAt!) > maxAge) {
      disposeAd(_ad as T);
      _ad = null;
      core.log(AdEventType.info, format, detail: 'cached ad expired, discarded');
      return false;
    }
    return true;
  }

  /// Takes the ready ad (the slot is empty afterwards).
  T? take() {
    if (!isReady) return null;
    final ad = _ad;
    _ad = null;
    return ad;
  }

  /// Starts loading when nothing is loaded or loading, subject to the retry
  /// state and the request budget. Safe to call as often as you like.
  void ensureLoaded({String reason = 'auto'}) {
    if (!core.canRequest || _loading || isReady) return;
    final id = core.unitId(format);
    if (id == null) return;

    final tracker = core.tracker('${format.name}:slot');
    if (!tracker.canRequest()) {
      core.log(AdEventType.blocked, format, detail: 'waiting for back-off/rest ($reason)');
      return;
    }
    if (!core.acquireBudget(format, null)) return;

    _loading = true;
    core.log(AdEventType.request, format, detail: reason);
    try {
      load(id, core.request, (ad) {
        _loading = false;
        _ad = ad;
        _loadedAt = core.now();
        tracker.onSuccess();
        core.log(AdEventType.loaded, format);
      }, (error) {
        _loading = false;
        core.log(AdEventType.failed, format, detail: 'code ${error.code}: ${error.message}');
        // Code 1 = invalid request (e.g. a wrong ad unit id): retrying cannot help.
        final delay = tracker.onFailure(fatal: error.code == 1);
        if (delay != null) {
          core.log(AdEventType.retryScheduled, format,
              detail: 'retry ${tracker.failures}/${core.policy.maxLoadRetries} in ${delay.inSeconds}s');
          _timer?.cancel();
          _timer = Timer(delay, () => ensureLoaded(reason: 'retry'));
        } else {
          core.log(AdEventType.gaveUp, format,
              detail: 'resting ${core.policy.giveUpCooldown.inSeconds}s before a new cycle');
        }
      });
    } catch (e) {
      _loading = false;
      core.log(AdEventType.failed, format, detail: 'load threw: $e');
    }
  }

  void dispose() {
    _timer?.cancel();
    if (_ad != null) disposeAd(_ad as T);
    _ad = null;
  }
}
