---
name: clip
description: Put a drafted message on the user's clipboard with real formatting (bullets, bold, links, headings) plus attached files (PDF, markdown) and images, ready to paste into Slack, Notes, Mail, etc. Use when the user asks to draft something and put it on their clipboard, or to "copy" content, files, or images for pasting.
---

# clip

`clip` writes rich, multi-item content to the macOS clipboard in one call. `pbcopy` only handles plain text, so use `clip` whenever formatting, files, or images matter.

The user has already configured which Mac's clipboard `clip` targets. If they paste on another Mac, `clip` copies the files there over SSH on its own. Don't pass `--remote` or `--local` unless the user names a specific machine.

## Commands

```bash
clip --md draft.md                                   # formatted text from markdown
cat <<'EOF' | clip --md -                            # same, from stdin
*Update*: shipped the thing
- bullet one
- bullet **two**
EOF
clip --md msg.md --file report.pdf --file notes.md   # text + file attachments
clip --md msg.md --file shot1.png --file shot2.png   # text + several images as attachments
clip --image chart.png                               # raw image pixels (Figma, Preview, docs)
clip --html msg.html                                 # raw HTML if markdown can't express it
clip --types                                         # check what is on the clipboard now
```

## Rules

- Write the message as markdown in a temp file, or pipe it in with a quoted heredoc (`<<'EOF'`) so the shell leaves it alone.
- For Slack, attach images with `--file` (one file reference per image). `--image` puts pixels on the clipboard, and apps usually read only the first image.
- Paths are local to the machine you run on and must exist. Two attached files can't share a filename, so rename one if they do.
- Each call replaces the clipboard. Put everything that should paste together into one call.
- If `clip` is missing, tell the user to install it from https://github.com/Pratham-commits-code/agent-clip.
- After it succeeds, tell the user what is on the clipboard (text, plus which files). Don't paste or send for them.
