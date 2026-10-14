import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'config.dart';
import 'guards.dart';

/// Counters per format, handy for checking behaviour (and for tests).
class AdStats {
  final Map<AdFormat, Map<AdEventType, int>> _counts = {};

  void record(AdEventType type, AdFormat format) {
    final m = _counts.putIfAbsent(format, () => {});
    m[type] = (m[type] ?? 0) + 1;
  }

  int count(AdFormat format, AdEventType type) => _counts[format]?[type] ?? 0;
  int requests(AdFormat f) => count(f, AdEventType.request);
  int loaded(AdFormat f) => count(f, AdEventType.loaded);
  int failed(AdFormat f) => count(f, AdEventType.failed);
  int shown(AdFormat f) => count(f, AdEventType.shown);
  int reused(AdFormat f) => count(f, AdEventType.reused);

  int get totalRequests =>
      AdFormat.values.fold(0, (sum, f) => sum + requests(f));

  String summary() {
    final buffer =
        StringBuffer('SafeAds stats (requests/loaded/failed/shown/reused):');
    for (final f in AdFormat.values) {
      if (requests(f) + shown(f) + reused(f) == 0) continue;
      buffer.write(
          '\n  ${f.name.padRight(20)} ${requests(f)}/${loaded(f)}/${failed(f)}/${shown(f)}/${reused(f)}');
    }
    return buffer.toString();
  }
}

/// Shared state of the running SafeAds instance. Treat as internal.
class SafeAdsCore {
  SafeAdsCore(
    this.config, {
    Clock? clock,
    ValueNotifier<bool>? readyNotifier,
    ValueNotifier<bool>? privacyNotifier,
  })  : policy = config.policy,
        budget =
            RequestBudget(max: config.policy.maxRequestsPerHour, clock: clock),
        _clock = clock ?? DateTime.now,
        ready = readyNotifier ?? ValueNotifier(false),
        privacyOptionsRequired = privacyNotifier ?? ValueNotifier(false);

  final SafeAdsConfig config;
  final AdPolicy policy;
  final RequestBudget budget;
  final Clock _clock;
  final AdStats stats = AdStats();

  /// True once consent allows ads and the Mobile Ads SDK is initialised.
  final ValueNotifier<bool> ready;

  /// True where the law requires a "Privacy options" entry point.
  final ValueNotifier<bool> privacyOptionsRequired;

  late InterstitialGate gate;

  bool fullScreenShowing = false;
  DateTime? lastFullScreenDismissedAt;
  DateTime? appOpenSuppressedUntil;

  final Map<String, RetryTracker> _trackers = {};
  final StreamController<AdEvent> _events =
      StreamController<AdEvent>.broadcast();
  final List<AdEvent> recentEvents = [];

  Stream<AdEvent> get events => _events.stream;
  DateTime now() => _clock();

  RetryTracker tracker(String key) => _trackers.putIfAbsent(
        key,
        () => RetryTracker(
          maxRetries: policy.maxLoadRetries,
          backoff: policy.retryBackoff,
          giveUpCooldown: policy.giveUpCooldown,
          clock: _clock,
        ),
      );

  String? unitId(AdFormat format) => config.useTestIds
      ? AdIds.testIds().forFormat(format)
      : config.ids.forFormat(format);

  AdRequest get request => config.request;

  bool get canRequest => config.enabled && ready.value;

  /// Reserves one request from the hourly budget (and logs when refused).
  bool acquireBudget(AdFormat format, String? placement) {
    if (budget.tryAcquire()) return true;
    log(AdEventType.blocked, format,
        placement: placement,
        detail: 'hourly request budget (${policy.maxRequestsPerHour}) used up');
    return false;
  }

  void log(AdEventType type, AdFormat? format,
      {String? placement, String? detail}) {
    final event = AdEvent(type, format, placement: placement, detail: detail);
    if (format != null) stats.record(type, format);
    recentEvents.add(event);
    if (recentEvents.length > 300) recentEvents.removeAt(0);
    if (config.logToConsole) debugPrint(event.toString());
    config.onEvent?.call(event);
    if (!_events.isClosed) _events.add(event);
  }
}

/// A tiny cache that lets a loaded banner/native ad be shown again on the next
/// visit to the same screen instead of requesting a new one every time.
///
/// An ad can live in only one place in the widget tree, so an entry is only
/// handed out while it is not attached, and only while younger than the
/// policy's max age.
class AdPool<T extends Ad> {
  final Map<String, _PoolEntry<T>> _entries = {};

  int get size => _entries.length;

  T? take(String key, Duration maxAge, DateTime now) {
    final e = _entries[key];
    if (e == null || e.attached) return null;
    if (now.difference(e.loadedAt) > maxAge) {
      e.ad.dispose();
      _entries.remove(key);
      return null;
    }
    e.attached = true;
    return e.ad;
  }

  /// Registers a freshly loaded ad that the caller is showing.
  void put(String key, T ad, DateTime now) {
    final old = _entries[key];
    if (old != null && !identical(old.ad, ad) && !old.attached) {
      old.ad.dispose();
    }
    _entries[key] = _PoolEntry(ad, now);
  }

  /// The screen that showed [ad] is gone: keep it for next time, or dispose it
  /// if it has been replaced meanwhile.
  void release(String key, T ad) {
    final e = _entries[key];
    if (e != null && identical(e.ad, ad)) {
      e.attached = false;
    } else {
      ad.dispose();
    }
  }
}

class _PoolEntry<T extends Ad> {
  _PoolEntry(this.ad, this.loadedAt);
  final T ad;
  final DateTime loadedAt;
  bool attached = true;
}
