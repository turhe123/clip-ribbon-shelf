# ClipRibbonShelf — specification

**Tagline:** A visual strip of clipboard cards that slides up from the screen bottom with pinboards for saved clips.

**Category:** Clipboard

**Inspired by (paid):** Paste ($3.99/month)

**Frameworks:** SwiftUI, AppKit, Carbon, ApplicationServices, UniformTypeIdentifiers, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does and evidence of demand. Paste is a well-known visual clipboard manager that shows copied items as a horizontal row of cards along the bottom of the screen, with pinboards for organizing frequently used clips. It is sold by subscription, with reviews quoting prices between roughly 1.99 and 3.99 dollars per month and a 14 day free trial, and it appears at the top of nearly every Mac clipboard roundup. The visual card approach is the main reason people choose it over text-list tools. Our clean-room version, ClipRibbonShelf, offers an original card strip and simple pinboards.

Feature set. The app records text, links, images, and file references. A global hotkey, default Shift plus Command plus C, slides a translucent shelf up from the bottom edge of the active screen, about 240 points high. Cards show a type-aware preview: wrapped text, a thumbnail for images, a title plus host for links, and the file icon and name for files. Each card shows the source app icon and a time stamp. Left and right arrows move through cards, Return pastes the chosen card, Space shows a larger quick look popover, and typing starts filtering. Pinboards are named collections, such as Work Email or Code, shown as tabs above the cards. Cards are added to a pinboard by dragging them to the tab or with Command plus the number key. The Escape key dismisses the shelf.

UI spec. The app is a MenuBarExtra with Show Shelf, Pause Capture, Settings, and Quit. The shelf is a borderless nonactivating NSPanel pinned to the bottom of the screen containing the pinboard tab bar, a search field that appears when typing begins, and a horizontally scrolling lazy stack of rounded cards. Tab list: History first, then user pinboards, then a plus button to create a new one, which uses an inline text field. Empty states: History shows a friendly message to copy something, and a pinboard shows Drag cards here. Settings fields: hotkey recorder, history length (100, 500, 1000), shelf height, card width, ignored apps list, image capture toggle, and Launch at login.

Technical approach. Poll the general pasteboard changeCount on a timer, reading string, URL, file URL, and image representations by priority using NSPasteboard types and UniformTypeIdentifiers checks. Generate image thumbnails with a downscaled NSImage drawn into a bitmap representation, and keep the full data in files inside Application Support. Link titles are derived from the URL host only, so no network access is needed. Animate the panel with a vertical offset spring animation and position it using NSScreen visibleFrame of the screen under the mouse. Paste action: write to the pasteboard, hide the shelf, reactivate the previous app, and post Command plus V with CGEvent, which requires Accessibility permission requested through AXIsProcessTrustedWithOptions with an explanatory first-run sheet. History and pinboards are stored as JSON with image files alongside. Register the hotkey through Carbon. Launch at login uses SMAppService.mainApp.

Edge cases and error handling. Without Accessibility permission, Return copies the card and shows a toast instructing the user to press Command V. On multi-display setups, show the shelf on the display containing the mouse. Fall back to a solid background when Reduce Transparency is enabled. Large images are downscaled before storage and anything over 20 megabytes is skipped. Deleting a pinboard asks for confirmation and moves its cards back to history. Corrupt storage is backed up and reset. Provide full keyboard operation and accessibility labels for cards so VoiceOver can read their type and preview.
