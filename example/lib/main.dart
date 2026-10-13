import 'dart:async';
import 'package:flutter/material.dart';
import 'package:safe_ads/safe_ads.dart';

/// Interactive test bench for every SafeAds feature (uses Google TEST ads).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SafeAds.init(
    const SafeAdsConfig(
      ids: AdIds(), // empty on purpose: test ids are used
      useTestIds: true,
      logToConsole: true,
      autoPreload: {AdFormat.interstitial, AdFormat.rewarded, AdFormat.rewardedInterstitial, AdFormat.appOpen},
      // Shorter than the defaults so the bench can be exercised quickly.
      policy: AdPolicy(
        launchGrace: Duration(seconds: 10),
        interstitialCooldown: Duration(minutes: 10),
        retryBackoff: Duration(seconds: 5),
        giveUpCooldown: Duration(seconds: 20),
      ),
    ),
  );
  runApp(const MaterialApp(home: Bench(), onGenerateRoute: _routes));
}

Route<dynamic>? _routes(RouteSettings s) {
  if (s.name == '/second') {
    return MaterialPageRoute(settings: s, builder: (_) => const SecondScreen());
  }
  return null;
}

class Bench extends StatefulWidget {
  const Bench({super.key});
  @override
  State<Bench> createState() => _BenchState();
}

class _BenchState extends State<Bench> {
  final List<String> _log = [];
  String _status = '';
  StreamSubscription<AdEvent>? _sub;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _sub = SafeAds.events.listen((e) {
      if (!mounted) return;
      setState(() {
        _log.insert(0, e.toString().replaceFirst('[SafeAds] ', ''));
        if (_log.length > 60) _log.removeLast();
      });
    });
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _say(String s) => setState(() => _status = s);

  @override
  Widget build(BuildContext context) {
    final ready = SafeAds.ready.value;
    return Scaffold(
      appBar: AppBar(title: const Text('SafeAds test bench')),
      bottomNavigationBar: const SafeBannerAd(placement: 'bench'),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('SDK ready: $ready   ·   ${SafeAds.stats.totalRequests} requests so far'),
          Text(SafeAds.stats.summary(), style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(
              onPressed: () async {
                await SafeAds.registerAction();
                _say('action registered');
              },
              child: const Text('+1 action'),
            ),
            FilledButton(
              onPressed: () async {
                final r = await SafeAds.showInterstitial(
                  placement: 'bench',
                  onFinished: () => _say('interstitial onFinished called'),
                );
                _say('interstitial -> $r');
              },
              child: const Text('Interstitial'),
            ),
            FilledButton(
              onPressed: () async {
                final r = await SafeAds.showRewarded(
                  placement: 'bench',
                  onReward: (reward) => _say('reward earned: ${reward.amount} ${reward.type}'),
                  onNotAvailable: () => _say('rewarded not ready yet'),
                );
                if (!r.shown) _say('rewarded -> $r');
              },
              child: const Text('Rewarded'),
            ),
            FilledButton(
              onPressed: () async {
                final r = await SafeAds.showRewardedInterstitial(
                  placement: 'bench',
                  onReward: (reward) => _say('reward earned: ${reward.amount} ${reward.type}'),
                );
                if (!r.shown) _say('rewarded interstitial -> $r');
              },
              child: const Text('Rewarded interstitial'),
            ),
            FilledButton(
              onPressed: () async => _say('app open -> ${await SafeAds.showAppOpen(placement: 'bench')}'),
              child: const Text('App open'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pushNamed('/second'),
              child: const Text('Open 2nd screen (banner reuse)'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('Status: $_status', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Native ad (medium):'),
          const SafeNativeAd(placement: 'bench-native'),
          const SizedBox(height: 12),
          const Text('Event log (newest first):'),
          for (final line in _log) Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5)),
        ],
      ),
    );
  }
}

class SecondScreen extends StatelessWidget {
  const SecondScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Second screen')),
        bottomNavigationBar: const SafeBannerAd(placement: 'second'),
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back (leave and re-enter to test reuse)'),
          ),
        ),
      );
}
