/// Strybok Flutter SDK.
///
/// Receives verified HTTPS links (iOS Universal Links / Android App Links),
/// resolves them through the Strybok API and delivers every link exactly once.
/// It can also create links to share (`Strybok.createLink`).
///
/// Links without an API call (path links and Firebase long links) are
/// optional and off by default (`parameterLinks`). Unit-tested only.
///
/// Deferred links (restoring a link after the app is installed from a store)
/// are optional and off by default (`deferredLinks`). The SDK has no native
/// code: on Android the app supplies the store's install referrer through
/// `installReferrerSources`; on iOS it hands over a link the person pasted
/// (`Strybok.redeemPastedLink`). Nothing of this has run on a device yet.
library;

export 'src/created_link.dart';
export 'src/deferred_links.dart'
    show
        DeferredLinkStatus,
        DeferredLinkStore,
        InstallReferrerAnswer,
        InstallReferrerSource,
        PastedLinkResult,
        deferredAttemptsKey,
        deferredDoneKey;
export 'src/exceptions.dart';
export 'src/link_bridge.dart';
export 'src/link_campaign.dart' show LinkCampaign;
export 'src/link_source.dart';
export 'src/parameter_links.dart' show ParameterLinks;
export 'src/resolved_deep_link.dart';
