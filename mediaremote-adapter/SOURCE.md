# mediaremote-adapter: where these files come from

This folder holds prebuilt files from
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
(BSD 3-Clause, © 2025 Jonas van den Berg and contributors). Hoverbird runs the adapter in a
separate `perl` process to read and control what's playing, which macOS requires since 15.4.

| | |
|---|---|
| Version | **v0.7.0** ([`252de63`](https://github.com/ungive/mediaremote-adapter/tree/252de63fee59dd8310191cba55d7ed46805ced4d)) |
| Test client | the next commit, [`dc0eb4b`](https://github.com/ungive/mediaremote-adapter/tree/dc0eb4bfd0aae1e5db574b249c656e3cbcee61f0). It only reverts a change to the test client's output (`setup_done` without a trailing newline), so the framework source is the same as v0.7.0 |
| Obtained from | boring.notch commit `61487af` (2025-08-14), unchanged |
| Built for | arm64 + x86_64, macOS 15.0 or later, macOS 15.5 SDK, ad-hoc signed |

How the version was identified: `mediaremote-adapter.pl` is byte-identical to the one in v0.7.0,
the framework has no arm64e slice (removed in v0.7.0), and the test client contains the strings
from `dc0eb4b`. boring.notch committed these files about four hours after `dc0eb4b`, and before
v0.7.1.

## Checksums (SHA-256)

```
91eb19837ca9f2779e476dc8e67d12bc28331dd557c87a19b0e45463c739c2fc  MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter
f177cc4a7d79ea5d70f330eac6266884527039196215738373ea813034285c2a  MediaRemoteAdapterTestClient
9ac5ed4532ad78431a85dd30e353efeca84391c4b84c760de74399c09cc2f2ca  mediaremote-adapter.pl
```

Check them with `shasum -a 256 -c` after any update. When you replace these files, update this
page and the version in `NOTICE`.

## Rebuild from source

```sh
git clone https://github.com/ungive/mediaremote-adapter.git
cd mediaremote-adapter
git checkout dc0eb4bfd0aae1e5db574b249c656e3cbcee61f0
mkdir build && cd build
cmake ..
cmake --build .
```

That produces `MediaRemoteAdapter.framework` and `MediaRemoteAdapterTestClient` in `build/`;
the script is `bin/mediaremote-adapter.pl`. A rebuild won't be byte-identical to these files
(different compiler, new signature), but it's the same source.
