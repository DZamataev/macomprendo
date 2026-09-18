# GitHub Pages redesign

## Pages and visual direction

Refresh the four existing English pages with navy, blue and pale-blue colours,
native sans-serif type, Phosphor Regular feature icons and the approved app icon.
The build copies AppIcon.png from the app source. Keep project-subpath-relative links,
generated versioned downloads and checksums, and PRIVACY.md as the privacy source.
Support and legal pages share the branding and a readable text layout.

## Landing page

Use “Now You {action} Without Typing” with a brief glitch transition between code,
rephrase, summarize, refine, write, reply and translate. Below it, show only
“Free offline dictation for every app”, download and compatibility information.
Provide a pause control and a static screen-reader equivalent. Reduced motion stops
rotation. No external fonts, scripts or tracking.

Use concise bullet points in four blocks, in this order:

- Your voice into text, with model-dependent languages, AI refinement, planned Parakeet
  and planned custom vocabulary.
- Text into speech, with system/local voices, compatible speech endpoints and configured
  voice switching for mixed English, Chinese and Russian passages.
- Private, explaining offline use, local Ollama, Keychain and optional local history.
- Free and open source, distinguishing MIT source from the GPL-3.0 distributed build.

Speech endpoints must support speech routes; chat compatibility alone is insufficient.
Copy follows the requested frontend-design and unslop skills, with short bullets taking
precedence over expanded prose. Follow the demo with native FAQ disclosures and download.

## Animated demo

Between features and FAQ, repeat a 24-second illustrative story. A marble Apollo head
with a cyan/magenta stripe across the eyes dictates “Use SQLite to save my notes”. A speech
bubble types “Use sequel light to save my notes”. The pixel coding agent in a monitor
imagines a lamp, becomes confused, smokes and develops crossed-out eyes. Cross out the
scene and repeat the dictation with correction.

At 13 seconds, the bubble turns green and the app icon bounces inside its bottom-right
corner. Strike through “sequel light”, then type “SQLite” beside it after a 400 ms delay.
Keep the visible correction and green bubble through the understood phase. The app icon
settles but stays visible; the agent shows a database and confirms the notes are saved.
At 19 seconds, show transparent human/robot hands forming a heart, with “Macomprendo”
and “when your mac understands”. Hold five seconds before restarting. No circular
background, extra final caption, visible disclaimer or textual Claude Code mentions.

Start when visible. Pause offscreen, in a hidden tab, or via Pause. Offer Replay.
Reduced motion and no JavaScript show a static successful state. Screen readers receive
one stable description. Avoid full-screen flashing; all decorative motion respects pause
and reduced-motion settings. Fit desktop and narrow mobile layouts.

## Generated artwork provenance

Built-in imagegen created these project assets:

- site/assets/apollo-glitch.png. Prompt: Apollo Belvedere marble head and neck, right-facing
  three-quarter view, monochrome marble, opaque cyan and hot-pink glitch stripe across the
  eyes, transparent background, no text or pedestal.
- site/assets/understanding-transparent.png. Derived from AppIcon.png via a pale-blue
  intermediate. Final prompt: remove the pale blue background, including inside the heart;
  preserve both hands and gesture; output only the hands on transparent alpha.

## Validation

Build the site and check local links, anchors and assets under a project subpath.
Test animation sequencing, correction typing, looping, pause, replay and reduced motion.
Run repository checks and inspect browser rendering with Peekaboo.
