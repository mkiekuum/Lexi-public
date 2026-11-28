# Lexi 3.7.0

<img src="Assets/LexiEmblem.png" width="80" alt="Lexi">

Local-first Japanese vocabulary notebook for macOS.

- Headwords, idioms, examples, notes, folders and duplicate indicators.
- Exact local dictionary matching, structured definitions and JSON import/export.
- Local MCP for vocabulary, folders, backups and dictionary connections.

## Install

Download the Apple silicon ZIP from Releases, extract and open Lexi.app. Requires macOS 14+, with Python 3 for dictionary lookup. The app is ad-hoc signed, not notarized. Intel builds have not been tested.

Select the installed Monokakido DAIJISEN2 product or a compatible Daijisen XML/TSV folder using the book icon. The native reader accesses individual articles on demand and caches only headline indexes. No full dictionary export is required. No dictionary data is bundled; saved definitions and notes remain available offline.

Data: ~/Library/Application Support/Lexi/Lexi.sqlite.

## MCP

Copy the configuration using the MCP icon. The bundled LexiMCP executable uses stdio. The lexi_dictionary_source tool accepts get, connect (absolute path), or disconnect, without requiring the GUI.

## Build

Install Xcode, Python 3, CMake and Ninja, then run bash install.command. The standalone native reader uses GPL-3.0-only mkd-tools; see NativeDictionary/README.md. Existing data is backed up before app installation.

To correct classifications in a pre-3.6 database, quit Lexi and its MCP clients, then run the included Scripts/repair_dictionary_sections.py with --db, --apply and --backup (a new backup path).

No personal records or commercial dictionary resources are included.
