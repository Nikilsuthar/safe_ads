/// One safe, reusable AdMob layer for Flutter apps.
///
/// See README.md for the quick start and the safety rules.
library;

export 'src/config.dart';
export 'src/core.dart' show AdStats;
export 'src/safe_ads.dart' show SafeAds;
export 'src/widgets.dart' show SafeBannerAd, SafeNativeAd, BannerSize;
export 'package:google_mobile_ads/google_mobile_ads.dart'
    show
        AdRequest,
        LoadAdError,
        NativeTemplateStyle,
        NativeTemplateTextStyle,
        RequestConfiguration,
        RewardItem,
        TemplateType;
