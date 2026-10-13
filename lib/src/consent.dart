import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Google's User Messaging Platform (UMP) consent flow. Gathers consent where
/// the law requires it (EEA / UK / Switzerland) BEFORE any ad is requested.
/// Every step has a timeout and a safe fallback, so a slow network can never
/// freeze the app - at worst ads start a little later (or not at all).
class ConsentManager {
  /// Requests consent info, shows the form if required, and reports whether
  /// ads may be requested.
  static Future<bool> gather() async {
    try {
      await _requestInfo().timeout(const Duration(seconds: 12));
      await _showFormIfRequired().timeout(const Duration(seconds: 60));
    } catch (_) {
      // Fall through: a cached consent state may still allow ads.
    }
    try {
      return await ConsentInformation.instance.canRequestAds();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> privacyOptionsRequired() async {
    try {
      final status = await ConsentInformation.instance.getPrivacyOptionsRequirementStatus();
      return status == PrivacyOptionsRequirementStatus.required;
    } catch (_) {
      return false;
    }
  }

  /// Re-opens the "Privacy options" form (offer it in your settings screen).
  /// Returns whether ads may be requested afterwards.
  static Future<bool> showPrivacyOptions() async {
    final completer = Completer<void>();
    try {
      await ConsentForm.showPrivacyOptionsForm((_) {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future.timeout(const Duration(minutes: 5));
      return await ConsentInformation.instance.canRequestAds();
    } catch (_) {
      return false;
    }
  }

  static Future<void> _requestInfo() {
    final completer = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () => completer.complete(),
      (error) => completer.completeError(error.message),
    );
    return completer.future;
  }

  static Future<void> _showFormIfRequired() {
    final completer = Completer<void>();
    ConsentForm.loadAndShowConsentFormIfRequired((error) {
      if (error != null) {
        completer.completeError(error.message);
      } else {
        completer.complete();
      }
    });
    return completer.future;
  }
}
