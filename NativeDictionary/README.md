# Lexi native dictionary reader

A standalone GPL-3.0-only process built with mkd-tools v0.10.0 (commit 02ac2e7eef3f949483e4ccb1be62f5c17b9c053e). It reads compatible, lawfully accessible local Daijisen resources. Lexi invokes this process without linking it into the Swift application.

Build with Scripts/build-native-dictionary.sh (CMake 3.31+, Ninja, Xcode). Upstream: https://github.com/kiwakiwaa/mkd-tools/tree/02ac2e7eef3f949483e4ccb1be62f5c17b9c053e. The script checks the pinned commit and initializes its pinned submodules. LICENSE is the GPL-3.0-only license of the helper and upstream.

The Release includes a corresponding source archive containing this helper, its build recipe, the exact upstream revision and its pinned third-party source trees and licenses. The archive can be built offline with CMake, Ninja and Xcode using the included build.sh.
