import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_ads/safe_ads.dart';
import 'package:safe_ads/src/core.dart';
import 'package:safe_ads/src/guards.dart';

class FakeClock {
  DateTime now = DateTime(2026, 1, 1, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('RequestBudget', () {
    test('allows up to max requests per window, then refuses', () {
      final clock = FakeClock();
      final budget = RequestBudget(max: 3, clock: clock.call);
      expect(budget.tryAcquire(), isTrue);
      expect(budget.tryAcquire(), isTrue);
      expect(budget.tryAcquire(), isTrue);
      expect(budget.tryAcquire(), isFalse);
      expect(budget.used, 3);
    });

    test('old requests fall out of the window', () {
      final clock = FakeClock();
      final budget = RequestBudget(max: 2, clock: clock.call);
      budget.tryAcquire();
      budget.tryAcquire();
      expect(budget.tryAcquire(), isFalse);
      clock.advance(const Duration(hours: 1, minutes: 1));
      expect(budget.tryAcquire(), isTrue);
    });
  });

  group('RetryTracker', () {
    RetryTracker make(FakeClock c) => RetryTracker(
          maxRetries: 2,
          backoff: const Duration(seconds: 30),
          giveUpCooldown: const Duration(minutes: 2),
          clock: c.call,
        );

    test('a cycle is the first request plus two retries (30 s, 60 s), then it rests', () {
      final clock = FakeClock();
      final t = make(clock);
      expect(t.canRequest(), isTrue);

      expect(t.onFailure(), const Duration(seconds: 30)); // failure 1 -> retry in 30 s
      expect(t.canRequest(), isFalse);
      clock.advance(const Duration(seconds: 30));
      expect(t.canRequest(), isTrue);

      expect(t.onFailure(), const Duration(seconds: 60)); // failure 2 -> retry in 60 s
      clock.advance(const Duration(seconds: 60));
      expect(t.canRequest(), isTrue);

      expect(t.onFailure(), isNull); // failure 3 -> gives up
      expect(t.gaveUp, isTrue);
      expect(t.attemptsPerCycle, 3);
    });

    test('after giving up it rests 2 minutes, then a new cycle may start', () {
      final clock = FakeClock();
      final t = make(clock);
      t.onFailure();
      t.onFailure();
      t.onFailure();
      clock.advance(const Duration(minutes: 1));
      expect(t.canRequest(), isFalse);
      clock.advance(const Duration(minutes: 1, seconds: 1));
      expect(t.canRequest(), isTrue);
      // The fresh cycle again allows two retries.
      expect(t.onFailure(), const Duration(seconds: 30));
    });

    test('a fatal error (invalid ad unit) rests 5x longer and never retries', () {
      final clock = FakeClock();
      final t = make(clock);
      expect(t.onFailure(fatal: true), isNull);
      clock.advance(const Duration(minutes: 9));
      expect(t.canRequest(), isFalse);
      clock.advance(const Duration(minutes: 2));
      expect(t.canRequest(), isTrue);
    });

    test('success resets everything', () {
      final clock = FakeClock();
      final t = make(clock);
      t.onFailure();
      t.onSuccess();
      expect(t.canRequest(), isTrue);
      expect(t.failures, 0);
    });
  });

  group('InterstitialGate', () {
    InterstitialGate make(FakeClock c, MemoryAdStorage s) =>
        InterstitialGate(policy: const AdPolicy(), storage: s, clock: c.call);

    test('blocks during the launch grace period', () {
      final clock = FakeClock();
      final g = make(clock, MemoryAdStorage());
      expect(g.check(), AdSkipReason.launchGrace);
      clock.advance(const Duration(seconds: 46));
      expect(g.check(), AdSkipReason.notEnoughActions);
    });

    test('needs two completed actions, then allows', () async {
      final clock = FakeClock();
      final g = make(clock, MemoryAdStorage());
      clock.advance(const Duration(minutes: 1));
      await g.registerAction();
      expect(g.check(), AdSkipReason.notEnoughActions);
      await g.registerAction();
      expect(g.check(), isNull);
    });

    test('after showing: counter resets and a 2-minute cooldown applies', () async {
      final clock = FakeClock();
      final g = make(clock, MemoryAdStorage());
      clock.advance(const Duration(minutes: 1));
      await g.registerAction();
      await g.registerAction();
      await g.markShown();
      await g.registerAction();
      await g.registerAction();
      expect(g.check(), AdSkipReason.cooldown);
      clock.advance(const Duration(minutes: 2, seconds: 1));
      expect(g.check(), isNull);
    });

    test('per-call minActions override', () async {
      final clock = FakeClock();
      final g = make(clock, MemoryAdStorage());
      clock.advance(const Duration(minutes: 1));
      expect(g.check(minActions: 0), isNull);
    });

    test('session cap stops further interstitials', () async {
      final clock = FakeClock();
      final g = InterstitialGate(
        policy: const AdPolicy(maxInterstitialsPerSession: 1, interstitialCooldown: Duration.zero),
        storage: MemoryAdStorage(),
        clock: clock.call,
      );
      clock.advance(const Duration(minutes: 1));
      await g.registerAction();
      await g.registerAction();
      await g.markShown();
      await g.registerAction();
      await g.registerAction();
      expect(g.check(), AdSkipReason.sessionCap);
    });

    test('counters persist through the storage object', () async {
      final storage = MemoryAdStorage();
      final clock = FakeClock();
      final first = make(clock, storage);
      await first.registerAction();
      await first.registerAction();
      final second = make(clock, storage); // "app restart"
      expect(second.actions, 2);
    });
  });

  group('AdPool', () {
    test('only constructed through real ads, so just check the age/attach contract of an empty pool', () {
      final pool = AdPool();
      expect(pool.take('k', const Duration(minutes: 5), DateTime.now()), isNull);
      expect(pool.size, 0);
    });
  });

  group('AdStats / ids', () {
    test('stats count events per format', () {
      final s = AdStats();
      s.record(AdEventType.request, AdFormat.banner);
      s.record(AdEventType.request, AdFormat.banner);
      s.record(AdEventType.loaded, AdFormat.banner);
      expect(s.requests(AdFormat.banner), 2);
      expect(s.loaded(AdFormat.banner), 1);
      expect(s.totalRequests, 2);
      expect(s.summary(), contains('banner'));
    });

    test('test ids exist for every format on both platforms', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        final ids = AdIds.testIds(platform);
        for (final f in AdFormat.values) {
          expect(ids.forFormat(f), startsWith('ca-app-pub-3940256099942544/'), reason: '$platform $f');
        }
      }
    });

    test('disabled SafeAds completes show calls immediately and still calls onFinished once', () async {
      var finished = 0;
      final result = await SafeAds.showInterstitial(onFinished: () => finished++);
      expect(result.shown, isFalse);
      expect(result.skipReason, AdSkipReason.disabled);
      expect(finished, 1);
    });
  });
}
