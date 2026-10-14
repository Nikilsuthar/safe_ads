import 'dart:math' as math;
import 'config.dart';

typedef Clock = DateTime Function();

DateTime _systemClock() => DateTime.now();

/// Key/value storage for the few counters that must survive app restarts.
abstract class AdStorage {
  int getInt(String key);
  Future<void> setInt(String key, int value);
}

class MemoryAdStorage implements AdStorage {
  final Map<String, int> _values = {};
  @override
  int getInt(String key) => _values[key] ?? 0;
  @override
  Future<void> setInt(String key, int value) async => _values[key] = value;
}

/// Hard cap on ad requests per rolling window - the last line of defence that
/// makes it impossible for a bug (or a navigation loop) to flood AdMob.
class RequestBudget {
  RequestBudget(
      {required this.max, this.window = const Duration(hours: 1), Clock? clock})
      : _clock = clock ?? _systemClock;

  final int max;
  final Duration window;
  final Clock _clock;
  final List<DateTime> _stamps = [];

  int get used {
    _trim();
    return _stamps.length;
  }

  /// Reserves one request. Returns false (and reserves nothing) when exhausted.
  bool tryAcquire() {
    _trim();
    if (_stamps.length >= max) return false;
    _stamps.add(_clock());
    return true;
  }

  void _trim() {
    final cutoff = _clock().subtract(window);
    _stamps.removeWhere((t) => t.isBefore(cutoff));
  }
}

/// Retry bookkeeping for one ad slot (one placement of one format).
///
/// A *cycle* is the first request plus up to `maxRetries` automatic retries
/// with growing back-off. When the cycle fails the slot rests for
/// `giveUpCooldown`; the next trigger after that starts a new cycle.
class RetryTracker {
  RetryTracker({
    required this.maxRetries,
    required this.backoff,
    required this.giveUpCooldown,
    Clock? clock,
  }) : _clock = clock ?? _systemClock;

  final int maxRetries;
  final Duration backoff;
  final Duration giveUpCooldown;
  final Clock _clock;

  int failures = 0;
  DateTime? nextAllowedAt;
  bool gaveUp = false;

  bool canRequest() {
    final at = nextAllowedAt;
    return at == null || !_clock().isBefore(at);
  }

  void onSuccess() {
    failures = 0;
    nextAllowedAt = null;
    gaveUp = false;
  }

  /// Records a failed load. Returns the delay for the automatic retry, or null
  /// when the cycle is over. [fatal] (e.g. an invalid ad unit id) ends the cycle
  /// at once with a much longer rest.
  Duration? onFailure({bool fatal = false}) {
    failures++;
    if (fatal || failures > maxRetries) {
      gaveUp = true;
      failures = 0;
      nextAllowedAt = _clock().add(fatal ? giveUpCooldown * 5 : giveUpCooldown);
      return null;
    }
    gaveUp = false;
    final delay = backoff * failures;
    nextAllowedAt = _clock().add(delay);
    return delay;
  }

  /// Total requests one cycle can make.
  int get attemptsPerCycle => 1 + math.max(0, maxRetries);
}

/// Decides whether an interstitial may be shown *now*.
class InterstitialGate {
  InterstitialGate({
    required this.policy,
    required this.storage,
    Clock? clock,
  })  : _clock = clock ?? _systemClock,
        startedAt = (clock ?? _systemClock)();

  static const String actionsKey = 'safe_ads_actions';
  static const String lastShownKey = 'safe_ads_interstitial_last';

  final AdPolicy policy;
  final AdStorage storage;
  final Clock _clock;
  final DateTime startedAt;
  int shownThisSession = 0;

  int get actions => storage.getInt(actionsKey);

  /// One completed user action (a QR saved, a level finished, ...).
  Future<void> registerAction() => storage.setInt(actionsKey, actions + 1);

  /// Null when an interstitial may be shown, otherwise the reason it may not.
  AdSkipReason? check({int? minActions}) {
    final now = _clock();
    if (now.difference(startedAt) < policy.launchGrace) {
      return AdSkipReason.launchGrace;
    }
    if (shownThisSession >= policy.maxInterstitialsPerSession) {
      return AdSkipReason.sessionCap;
    }
    final lastMs = storage.getInt(lastShownKey);
    if (lastMs != 0 &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(lastMs)) <
            policy.interstitialCooldown) {
      return AdSkipReason.cooldown;
    }
    if (actions < (minActions ?? policy.minActionsBetweenInterstitials)) {
      return AdSkipReason.notEnoughActions;
    }
    return null;
  }

  /// Call when an interstitial was actually displayed.
  Future<void> markShown() async {
    shownThisSession++;
    await storage.setInt(lastShownKey, _clock().millisecondsSinceEpoch);
    await storage.setInt(actionsKey, 0);
  }
}
