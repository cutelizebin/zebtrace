# README assets

`recording-library-light.png` is a 2400 × 1560 interface preview rendered on macOS
from the ZebTrace 0.4.3 library views and native toolbar. Display it at 1200 pixels
wide or smaller.

All four recording entries and their transcript/summary text are authored sample
content. The temporary fixture audio is synthesized silence; the text is not
inference output and does not demonstrate recognition accuracy. No personal
recordings, model weights, names, or file paths are included in the image.

A separate temporary preview app rendered the existing SwiftUI components. Its
sidebar used an opaque container because the macOS 26 glass sidebar does not
reliably appear in native bitmap capture. Product source and behavior were not
changed. The preview did not record, play audio, or run inference.

These project-authored assets are included under the repository's [MIT license](../../LICENSE).
The app icon is reused from [Resources/AppIcon.png](../../Resources/AppIcon.png);
its provenance is documented in [branding.md](../branding.md).
