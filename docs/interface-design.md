# Recording library interface

The library should make three actions immediate: record, choose a recording, and read or listen. File operations and model maintenance remain available without occupying the reading area. The local preview implements this hierarchy using native macOS window controls and SwiftUI content.

## Apple guidance

The design uses the following Human Interface Guidelines, checked on 2026-09-06:

| Guidance | Application to ZebTrace |
| --- | --- |
| [Design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles) | Keep the necessary actions close at hand and express their priority clearly. A smaller number of visible controls should make the common tasks easier, rather than require extra navigation. |
| [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Use a compact native window toolbar for frequent actions. Avoid a separate custom control strip competing with the title bar, and move occasional operations to a menu. |
| [Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | Put the selected recording's content near the top. Use alignment and whitespace to group related information; avoid repeating its status, source icons, and title in several places. |
| [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) | Keep date groups and recording rows concise. Use a resizable list with familiar selection behavior, leaving sufficient space for the document. Critical recording controls must not depend on the sidebar's bottom edge being visible. |
| [Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls) | Keep play/pause directly accessible, while revealing track and segment choices only when needed. Secondary options should not push the summary below the initial viewport. |
| [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) | Use system fonts, a small set of text styles, and weight/spacing to establish hierarchy. Body text should be easy to read, with compact metadata and modest section headings. |
| [Settings](https://developer.apple.com/design/human-interface-guidelines/settings) | Keep settings separate from frequent document actions. For ZebTrace's accessory app, the existing menu-bar entry remains available; do not duplicate model/storage controls throughout the document. |

The current HIG also describes materials introduced in recent operating systems. ZebTrace keeps macOS 14.2 support, uses native controls and semantic colors, and lets the installed system supply its appearance. A custom imitation of newer glass effects is unnecessary.

## Content and action hierarchy

| Area | Visible by default | Available on demand |
| --- | --- | --- |
| Window toolbar | Sidebar toggle, Record / Stop & Save | More: regenerate, copy, files, deletion, refresh |
| Recording list | Search, date groups, time, duration, short preview | Recording context menu |
| Detail heading | Recording date/time, concise status, summary/transcript switch | — |
| Reader | Summary/transcript navigation and document content | Diagnostic details when an error requires them |
| Audio playback | A compact play/pause control and current source | Alternate source and additional segments when present |
| No summary yet | One clear action to generate a review | Existing transcript if a previous summary attempt failed |
| Processing | Progress for the selected recording | Cancel in More; validated saved transcript stays accessible |

The same action should not appear as both a permanent header button and a duplicate button in the empty state. Actions that can discard data retain their explicit confirmation flow even when accessed through a menu.

## Interaction constraints

- Selecting a recording changes the entire detail context. Switching records stops playback; opening a window or changing a selection never starts recording, playback, or inference automatically.
- Source selection must describe the real playback behavior. Separate captured tracks must not be presented as synchronized mixed playback unless that behavior is actually implemented.
- Single-segment recordings do not need a segment picker. Longer recordings retain access to every saved segment.
- Native selection, keyboard focus, and resizing behavior take precedence over decorative cards. A search field should not take initial focus away from reading unless the user chooses search.
- Icon-only controls need localized accessibility labels and help text. Status must not rely on color alone, and localized labels must have room to expand.
- Use semantic foreground and background colors so active/inactive windows, light/dark appearance, and the user's accent color remain legible.

Verification should cover a narrow and a normal-size window, both shipped languages, light/dark appearance, empty/processing/completed recordings, source switching, and a recording with multiple segments. Build and automated test results alone do not establish visual quality.

## Local verification (2026-09-06)

The 0.4.1 (build 7) preview passed 125 automated tests and Universal app/helper verification. Native component snapshots covered Chinese/light and English/dark presentation, a 780 × 520 window, ready and unsummarized recordings, an empty library, the recording toolbar state, and the transcript reader. A separate AppKit probe checked the collapsed-sidebar toolbar, English Stop & Save label, and enabled/disabled Command-R behavior.

macOS 26 glass layers are omitted by `cacheDisplay` when capturing the entire native window. The sidebar was therefore checked separately with the same SwiftUI component in a plain temporary native window. These snapshots verify content/layout; they are not a full desktop capture or an exhaustive accessibility audit. Preview fixtures did not run capture, inference, or audio playback.

The final ZIP was extracted outside the checkout and its app installed locally. The DMG was mounted read-only, verified and detached. Both passed architecture, deployment-target, localization, signature and system-library dependency checks. Original audio and manifests remained unchanged. These checks were performed on the unpublished 0.4.1 build, before the 0.4.3 preview release.
