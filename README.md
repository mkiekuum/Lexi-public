# Lexi 3.6.0

<img src="Assets/LexiEmblem.png" width="80" alt="Lexi">

Local-first Japanese vocabulary notebook for macOS.

- Headwords, idioms, examples, notes, folders and duplicate indicators.
- Exact local dictionary matching, structured definitions and JSON import/export.
- Local MCP for vocabulary, folders, backups and dictionary connections.

## Install

Download the Apple silicon ZIP from Releases, extract and open Lexi.app. Requires macOS 14+, with Python 3 for dictionary lookup. The app is ad-hoc signed, not notarized. Intel builds have not been tested.

Select a lawfully obtained compatible Daijisen XML/TSV folder using the book icon. The folder needs Contents and Headline, with headline.headlinestore.tsv and short-headline.headlinestore.tsv. No dictionary data is bundled; saved definitions and notes remain available offline.

Data: ~/Library/Application Support/Lexi/Lexi.sqlite.

## MCP

Copy the configuration using the MCP icon. The bundled LexiMCP executable uses stdio. The lexi_dictionary_source tool accepts get, connect (absolute path), or disconnect, without requiring the GUI.

## Build

Install Xcode and Python 3, then run bash install.command. Existing data is backed up before app installation.

To correct classifications in a pre-3.6 database, quit Lexi and its MCP clients, then run the included Scripts/repair_dictionary_sections.py with --db, --apply and --backup (a new backup path).

No personal records or commercial dictionary resources are included.
