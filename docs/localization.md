# Localization

User-facing app text belongs in localization resources, including menu items, library controls, model/storage management, errors, and accessibility labels. Call `L10n.string` with a stable semantic key; do not put English/Chinese alternatives or language-specific text branches into a view or controller. Model names, filenames, protocol identifiers, and machine-readable metadata are not translated.

## Add a language

1. Add a case with its language identifier to `AppLanguage` in `Sources/ZebTraceCore/Localization.swift`, for example `case french = "fr"`. The system resolver and language menus use this registry. Add `language.option.fr` to every locale so each language menu can name the new choice. Keep English as the development fallback.
2. Add `Sources/ZebTraceCore/Resources/fr.lproj/Localizable.strings` with the complete key set. This table serves the app and core/analysis modules through `L10n`; the app has no separate duplicate UI string table. Preserve format placeholders and argument types. Translate whole phrases rather than assembling language-dependent sentence fragments in code.
3. Add `Resources/fr.lproj/InfoPlist.strings` for the main app's microphone and system-audio purpose descriptions, and add `fr` to `CFBundleLocalizations` in `Resources/Info.plist`. These permission resources must be in the main app, separately from the SwiftPM bundle. Build and verification scripts enumerate the declared locales automatically.
4. Review the `review.prompt.*` resources as inference instructions, separately from the UI copy. Evaluate the requested output language on synthetic transcripts, then exercise language selection, formatted values, long labels, errors, and the packaged app.

`Package.swift` processes the core resource directory and declares English as `defaultLocalization`; adding another `.lproj` does not require a new target. `L10n` loads resources from the installed app before using SwiftPM's development bundle, and accepts SwiftPM's lowercased locale directory names. A new language must work after moving the app away from its source checkout.

`AppLanguage.matching` normalizes regional identifiers centrally. Its base-language fallback currently lets supported languages cover regional variants. If introducing multiple scripts or regional translations for one language, extend and test that central resolution policy; do not scatter special cases through the UI. Dates and numeric presentation should use the resolved locale, while manifest timestamps, source names, and recording directory formats stay stable and language-independent.

## UI language and model language

Changing the app language refreshes interface presentation without restarting capture. A review snapshots its requested summary language at the start; changing the UI while it runs does not rewrite that job's language or existing saved results. Speech recognition independently detects the spoken language. Adding a translated interface does not establish recognition or summary quality for that language.

The summary provider resolves `review.prompt.system`, `review.prompt.transcript`, and `review.prompt.combine` using the job's explicit output language. These keys currently share the `Localizable.strings` table for packaging convenience, but have a separate behavioral role: preserve evidence-only summarization, uncertainty, source references, and the distinction between audio tracks and speakers. Do not translate the provider's runtime protocol tokens or alter session metadata to match UI labels. Include prompt changes in inference review and synthetic-output checks; key parity alone cannot verify their meaning.

System-owned permission dialogs follow macOS language rules rather than the app's in-process language toggle. Low-level operating-system and helper diagnostics may remain in their own language; primary app errors and recovery actions should still use resource keys.

## Checks

`LocalizationTests` iterates every registered non-system language, requires the same nonempty keys as English, verifies format specifiers, and confirms that the expected resource bundle exists. Add resolver cases for new regional/script behavior and update targeted formatting assertions when introducing new plural rules. Keep placeholders such as `%@`, `%ld`, and `%d` intact and type-compatible.

Run the relevant source checks and then the complete app check:

```sh
swift test --filter LocalizationTests
make check
```

`scripts/verify-app.sh` checks every advertised locale in the extracted app, including both `InfoPlist.strings` and core `Localizable.strings`. Before distribution, inspect the library, model/storage windows, context menus, accessibility labels, and first-use permission text in every supported language. Confirm that changing languages leaves the selected session, active recording, and saved documents intact.
