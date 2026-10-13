# Changelog

## 0.1.0
- First release: banner (adaptive/inline/fixed), native, interstitial, rewarded, rewarded interstitial and app-open ads.
- UMP consent, request budget (120/h), capped retries (3 attempts then a 2-minute rest), banner/native reuse for 5 minutes,
  interstitial pacing (launch grace, cooldown, action count, session cap), persisted counters, event stream and stats.
- Verified on a device with Google test ads (all formats, failure/retry path, cooldown across restarts, banner reuse).
