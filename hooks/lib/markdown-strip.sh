#!/bin/bash
# markdown-strip.sh — pure, unit-tested transform for outbound agent chat text.
#
# hqpa_markdown_strip reads stdin and writes a plain, human, chat-ready version to
# stdout: no markdown emphasis, no headings, no code fences, no tables, no
# "orange variable-name" backtick styling, no bullet glyph noise. It is the
# transform behind the Slack markdown-strip behavior; kept as a standalone
# function so it can be unit-tested in isolation (input -> expected plain output)
# and reused by any channel skill.
#
# Deliberately conservative: it normalizes formatting to plain text but preserves
# the words, URLs, and line meaning. Idempotent — running it twice equals once.

hqpa_markdown_strip() {
  sed -E '
    # Strip fenced-code markers (```lang / ```), keep the code lines as plain text.
    s/^[[:space:]]*```[A-Za-z0-9_-]*[[:space:]]*$//
    # Headings: "### Title" -> "Title"
    s/^[[:space:]]*#{1,6}[[:space:]]+//
    # Blockquote markers: "> text" -> "text"
    s/^[[:space:]]*>[[:space:]]?//
    # Bullet list glyphs at line start (-, *, +) -> "- " normalized to nothing noisy
    s/^[[:space:]]*[-*+][[:space:]]+/- /
    # Bold/italic: **x** __x__ *x* _x_  -> x
    s/\*\*([^*]+)\*\*/\1/g
    s/__([^_]+)__/\1/g
    s/\*([^*]+)\*/\1/g
    s/(^|[^A-Za-z0-9_])_([^_]+)_([^A-Za-z0-9_]|$)/\1\2\3/g
    # Inline code / the "orange variable" styling: `code` -> code
    s/`([^`]*)`/\1/g
    # Strikethrough ~~x~~ -> x
    s/~~([^~]+)~~/\1/g
    # Markdown links [text](url) -> text (url)
    s/\[([^]]+)\]\(([^)]+)\)/\1 (\2)/g
    # Table pipe rows: drop separator rows like |---|---|
    /^[[:space:]]*\|?[[:space:]]*:?-{2,}.*$/d
  ' | \
  # Collapse 3+ blank lines to a single blank line (chat prefers compact).
  awk 'BEGIN{blank=0} { if ($0 ~ /^[[:space:]]*$/) { blank++; if (blank<=1) print ""; } else { blank=0; print } }'
}

# If executed (not sourced), act as a filter: stdin -> stripped stdout.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  hqpa_markdown_strip
fi
