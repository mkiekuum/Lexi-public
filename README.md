# Lexi 3.5.0

<img src="Assets/LexiEmblem.png" width="96" alt="Lexi logo">

A local-first Japanese vocabulary notebook for macOS, written in SwiftUI with SQLite.

- Independent headwords, idioms and examples, notes, folders and multi-selection.
- Exact dictionary-title matching, ambiguity previews, multiple candidate selection and batch skipping.
- Structured dictionary rendering with ruby, grammar markers and subtle example highlighting.
- Global font and size settings, light/dark themes, filters and local MCP (stdio).
- Portable JSON export/import with dictionary reference IDs and content; existing notes are preserved.

## Install

Download the Apple silicon app-only ZIP from Releases, extract it, and move Lexi.app into a folder of your choice. The app is ad-hoc signed, not notarized by Apple; macOS may require opening it via its normal security confirmation. No dictionary or user data is included.

macOS 14 or later is the declared minimum; the binary was built and tested on an Apple silicon Mac. Intel binary and older-macOS compatibility have not been tested.

To build from source, install Xcode with the macOS SDK and Python 3, quit Lexi, then run:

```sh
bash install.command
```

The installer tests and builds the GUI and MCP executable, installs to ~/Desktop/Lexi, and backs up existing user data before replacing the app. The notebook works without a dictionary. For optional dictionary lookup, provide lawfully obtained compatible local XML and headline indexes at ~/Desktop/Lexi/Dictionary/DAIJISEN.J/{Contents,Headline}; set LEXI_DICTIONARY_PATH to use another location. Copy Scripts/daijisen_parser.py into the dictionary root when using the prebuilt app. Both headline.headlinestore.tsv and short-headline.headlinestore.tsv are required. No commercial dictionary resources are distributed here.

Data lives in ~/Library/Application Support/Lexi/Lexi.sqlite. The bundled MCP executable is in Lexi.app/Contents/Resources/LexiMCP; use the app's MCP toolbar button to copy configuration, or point your client to that executable with --db and the database path.

## Testing

```sh
swift test --build-system native --jobs 2
swift build --build-system native --jobs 2 -c release --product LexiMCP
LEXI_MCP_BINARY="$(swift build --build-system native -c release --show-bin-path)/LexiMCP" python3 -m unittest discover -s Tests -p 'test_*.py'
```

Tests requiring optional real dictionary resources or a disposable database fixture may skip. Never point a test fixture at a live database.

This public source snapshot excludes personal vocabulary, notes, database backups, imported spreadsheets, private development history and third-party dictionary files. No additional redistribution license is declared.
