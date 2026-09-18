#!/usr/bin/env node
// Convert a Markdown file into a single self-contained HTML file.
//
//   node md2html.cjs <input.md> [output.html]
//
// The output embeds all CSS and JS (no CDN, no external files) and adds a
// "Copy" button to every fenced code block. Markdown parsing is done at build
// time by the vendored `marked` (assets/marked.umd.js, MIT).
'use strict';

const fs = require('fs');
const path = require('path');

const markedModule = require(path.join(__dirname, '..', 'assets', 'marked.umd.js'));
const marked = markedModule.marked || markedModule;

// GitHub-style alerts (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`,
// `> [!CAUTION]`) are rendered as colored callouts. Unknown types fall back to a
// neutral callout, so the syntax can be reused for environment labels.
const ALERT_TITLES = {
    NOTE: 'Note',
    TIP: 'Tip',
    IMPORTANT: 'Important',
    WARNING: 'Warning',
    CAUTION: 'Caution',
};

marked.use({
    renderer: {
        blockquote({ tokens }) {
            const body = this.parser.parse(tokens);
            const first = tokens[0];
            let type = null;
            if (first && first.type === 'paragraph' && first.text) {
                const match = first.text.match(/^\[!([A-Za-z][\w-]*)\]\s*/);
                if (match) type = match[1].toUpperCase();
            }
            if (!type) {
                return `<blockquote>\n${body}</blockquote>\n`;
            }
            const title =
                ALERT_TITLES[type] ||
                type.replace(/[-_]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
            const inner = body.replace(new RegExp(`\\[!${type}\\]\\s*`), '');
            return (
                `<div class="callout callout-${type.toLowerCase()}">` +
                `<p class="callout-title">${escapeHtml(title)}</p>` +
                `<div class="callout-body">${inner}</div>` +
                '</div>\n'
            );
        },
    },
});

function escapeHtml(value) {
    return String(value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function titleFrom(markdown, fallback) {
    const match = markdown.match(/^\s*#\s+(.+?)\s*$/m);
    return match ? match[1].trim() : fallback;
}

// Wrap each <pre><code> in a container with a header row holding the language
// label and the copy button. `marked` HTML-escapes code content, so the only
// literal </code></pre> in `html` is the block terminator.
function addCopyButtons(html) {
    return html.replace(
        /<pre><code([^>]*)>([\s\S]*?)<\/code><\/pre>/g,
        (_match, attrs, code) => {
            const langMatch = attrs.match(/\bclass="[^"]*language-([^"\s]+)/);
            const lang = langMatch ? escapeHtml(langMatch[1]) : '';
            return (
                '<div class="code-block">' +
                '<div class="code-head">' +
                `<span class="code-lang">${lang}</span>` +
                '<button class="copy-btn" type="button">Copy</button>' +
                '</div>' +
                `<pre><code${attrs}>${code}</code></pre>` +
                '</div>'
            );
        }
    );
}

const STYLE = `
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
    margin: 0;
    padding: 2rem 1rem 4rem;
    background: #f6f7f9;
    color: #1f2328;
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
}
main {
    max-width: 52rem;
    margin: 0 auto;
    background: #fff;
    border: 1px solid #d8dee4;
    border-radius: 10px;
    padding: 1.5rem 2rem 2.5rem;
    box-shadow: 0 1px 3px rgba(0, 0, 0, .06);
}
h1, h2, h3, h4 { line-height: 1.25; margin: 1.6em 0 .6em; }
h1 { font-size: 1.9rem; border-bottom: 1px solid #d8dee4; padding-bottom: .3em; }
h2 { font-size: 1.4rem; border-bottom: 1px solid #e6eaef; padding-bottom: .25em; }
h3 { font-size: 1.15rem; }
a { color: #0969da; }
p, ul, ol, blockquote { margin: .8em 0; }
code {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
    font-size: .9em;
    background: #eff1f3;
    border-radius: 5px;
    padding: .15em .35em;
}
blockquote {
    margin: 1em 0;
    padding: .1em 1em;
    color: #57606a;
    border-left: .25em solid #d0d7de;
    background: #f6f8fa;
    border-radius: 0 6px 6px 0;
}
.callout {
    margin: 1em 0;
    padding: .75rem 1rem;
    border-left: .25rem solid var(--callout-color, #57606a);
    border-radius: 6px;
    background: var(--callout-bg, #f6f8fa);
}
.callout-title {
    margin: 0 0 .35em;
    font-weight: 600;
    color: var(--callout-color, #57606a);
}
.callout-body > :first-child { margin-top: 0; }
.callout-body > :last-child { margin-bottom: 0; }
.callout-note      { --callout-color: #0969da; --callout-bg: rgba(9, 105, 218, .08); }
.callout-tip       { --callout-color: #1a7f37; --callout-bg: rgba(26, 127, 55, .08); }
.callout-important { --callout-color: #8250df; --callout-bg: rgba(130, 80, 223, .08); }
.callout-warning   { --callout-color: #9a6700; --callout-bg: rgba(154, 103, 0, .08); }
.callout-caution   { --callout-color: #cf222e; --callout-bg: rgba(207, 34, 46, .08); }
hr { border: 0; border-top: 1px solid #d8dee4; margin: 2em 0; }
table { border-collapse: collapse; margin: 1em 0; }
th, td { border: 1px solid #d0d7de; padding: .4em .7em; text-align: left; }
th { background: #f6f8fa; }
.code-block {
    position: relative;
    margin: 1em 0;
    border: 1px solid #d8dee4;
    border-radius: 8px;
    overflow: hidden;
    background: #f6f8fa;
}
.code-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: .5rem;
    padding: .3rem .5rem .3rem .8rem;
    background: #eef1f4;
    border-bottom: 1px solid #d8dee4;
}
.code-lang {
    font: 600 .75rem/1 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    color: #57606a;
    text-transform: lowercase;
}
.code-lang:empty { display: none; }
.copy-btn {
    font: 500 .78rem/1 inherit;
    color: #24292f;
    background: #fff;
    border: 1px solid #d0d7de;
    border-radius: 6px;
    padding: .35rem .6rem;
    cursor: pointer;
}
.copy-btn:hover { background: #f3f4f6; }
.copy-btn:active { transform: translateY(1px); }
.copy-btn.copied { color: #1a7f37; border-color: #1a7f37; }
.code-block pre {
    margin: 0;
    padding: .9rem 1rem;
    overflow-x: auto;
    background: #f6f8fa;
}
.code-block pre code {
    display: block;
    padding: 0;
    background: none;
    border-radius: 0;
    font-size: .86rem;
    line-height: 1.55;
    white-space: pre;
}
@media (prefers-color-scheme: dark) {
    body { background: #0d1117; color: #e6edf3; }
    main { background: #161b22; border-color: #30363d; box-shadow: none; }
    h1, h2 { border-color: #30363d; }
    a { color: #4493f8; }
    code { background: #21262d; }
    blockquote { color: #9198a1; background: #161b22; border-color: #30363d; }
    .callout-note      { --callout-color: #4493f8; --callout-bg: rgba(56, 139, 253, .15); }
    .callout-tip       { --callout-color: #3fb950; --callout-bg: rgba(63, 185, 80, .15); }
    .callout-important { --callout-color: #ab7df8; --callout-bg: rgba(163, 113, 247, .15); }
    .callout-warning   { --callout-color: #d29922; --callout-bg: rgba(187, 128, 9, .15); }
    .callout-caution   { --callout-color: #f85149; --callout-bg: rgba(248, 81, 73, .15); }
    th, td { border-color: #30363d; }
    th { background: #21262d; }
    .code-block { border-color: #30363d; background: #0d1117; }
    .code-head { background: #21262d; border-color: #30363d; }
    .code-lang { color: #9198a1; }
    .copy-btn { color: #e6edf3; background: #21262d; border-color: #30363d; }
    .copy-btn:hover { background: #30363d; }
    .code-block pre { background: #0d1117; }
}
`;

const SCRIPT = `
(function () {
    function copyText(text) {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        }
        return new Promise(function (resolve, reject) {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.setAttribute('readonly', '');
            ta.style.position = 'fixed';
            ta.style.top = '-1000px';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            try {
                var ok = document.execCommand('copy');
                ta.remove();
                ok ? resolve() : reject(new Error('copy failed'));
            } catch (err) {
                ta.remove();
                reject(err);
            }
        });
    }

    document.addEventListener('click', function (event) {
        var target = event.target;
        if (!target || typeof target.closest !== 'function') return;
        var btn = target.closest('.copy-btn');
        if (!btn) return;
        var block = btn.closest('.code-block');
        var code = block && block.querySelector('pre code');
        if (!code) return;
        copyText(code.textContent).then(function () {
            btn.textContent = 'Copied!';
            btn.classList.add('copied');
            setTimeout(function () {
                btn.textContent = 'Copy';
                btn.classList.remove('copied');
            }, 1500);
        }).catch(function () {
            btn.textContent = 'Copy failed';
            setTimeout(function () { btn.textContent = 'Copy'; }, 1500);
        });
    });
})();
`;

function render(inputPath, outputPath) {
    const markdown = fs.readFileSync(inputPath, 'utf8');
    const title = titleFrom(markdown, path.basename(inputPath));
    const body = addCopyButtons(marked.parse(markdown, { gfm: true }));
    const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>${STYLE}</style>
</head>
<body>
<main>
${body}
</main>
<script>${SCRIPT}</script>
</body>
</html>
`;
    fs.writeFileSync(outputPath, html);
    return { title, outputPath };
}

function main(argv) {
    const input = argv[0] || 'INSTALL.md';
    if (!fs.existsSync(input)) {
        console.error(`error: input file not found: ${input}`);
        process.exit(1);
    }
    const output =
        argv[1] || path.basename(input).replace(/\.(md|markdown)$/i, '') + '.html';
    if (path.resolve(input) === path.resolve(output)) {
        console.error('error: output must differ from input');
        process.exit(1);
    }
    const result = render(input, output);
    console.log(`wrote ${result.outputPath} (title: ${result.title})`);
}

main(process.argv.slice(2));
