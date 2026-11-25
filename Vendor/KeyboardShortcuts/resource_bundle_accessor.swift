// Added by Hoverbird: SwiftPM normally generates this accessor. The app bundles
// KeyboardShortcuts' localizations at Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle.
import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let name = "KeyboardShortcuts_KeyboardShortcuts.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(name), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle.main
    }()
}
