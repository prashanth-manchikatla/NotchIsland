# Vendored dependencies

Hoverbird builds with plain `swiftc` (see `Scripts/build.sh`), so its Swift
package dependencies are vendored here as source, pinned to the versions
boring.notch resolved:

| Module | Upstream | Version | License |
|---|---|---|---|
| Defaults | github.com/sindresorhus/Defaults | 9.0.6 | MIT |
| KeyboardShortcuts | github.com/sindresorhus/KeyboardShortcuts | 2.4.0 | MIT |
| LaunchAtLogin | github.com/sindresorhus/LaunchAtLogin-Modern | 1.1.0 | MIT |
| SwiftUIIntrospect | github.com/siteline/swiftui-introspect | 1.3.0 | MIT |
| SkyLightWindow | github.com/Lakr233/SkyLightWindow | 1.0.0 | MIT |
| MacroVisionKit | github.com/TheBoredTeam/MacroVisionKit | 0.2.0 | see upstream |

Local change: `KeyboardShortcuts/resource_bundle_accessor.swift` replaces the
SwiftPM-generated `Bundle.module` accessor.
