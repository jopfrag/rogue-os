---
name: md-to-html
description: Convert a Markdown file (for example INSTALL.md) into a single self-contained HTML file with inline CSS/JS, no external dependencies, and a Copy button on every fenced code block. Use when asked to turn a Markdown document into a standalone, shareable HTML page or to render INSTALL.md as HTML.
---

# Markdown to self-contained HTML

Convert a Markdown document into one standalone `.html` file. All styling and
JavaScript are embedded, so the result works offline and from `file://` with no
CDN or sibling assets. Every fenced code block gets a language label and a
**Copy** button.

## Usage

Run the script from the repository root. With no arguments it converts
`INSTALL.md` to `INSTALL.html` next to it:

```sh
node .pi/skills/md-to-html/scripts/md2html.cjs INSTALL.md
```

Explicit output path:

```sh
node .pi/skills/md-to-html/scripts/md2html.cjs INSTALL.md /tmp/INSTALL.html
```

Usage summary:

```text
node scripts/md2html.cjs [input.md] [output.html]
```

- `input.md` defaults to `INSTALL.md`.
- `output.html` defaults to the input name with `.html` instead of `.md`.
- The document title is taken from the first ATX `# ` heading.

## Details

- Markdown is parsed at build time with the vendored `marked`
  (`assets/marked.umd.js`, MIT; see `assets/marked.LICENSE`). The generated HTML
  has **no** runtime dependency on it.
- Copy buttons use `navigator.clipboard` and fall back to a hidden
  `document.execCommand('copy')` textarea, so copying works from `file://`.
- The page supports light and dark color schemes automatically.

## Verify

After converting, check that the output has no external references:

```sh
grep -nE '<(link|script)[^>]+(src|href)=' INSTALL.html   # expected: no output
```

The number of `copy-btn` occurrences should match the number of fenced code
blocks in the source (`grep -c '```' INSTALL.md` counts opening and closing
fences, so divide by two).
