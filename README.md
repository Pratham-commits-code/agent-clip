# agent-clip

A clipboard tool for AI agents on macOS. Ask your agent to draft a Slack message with bullets, a PDF and a couple of screenshots, and it all lands on your clipboard in one go, ready to paste.

`pbcopy` only handles plain text. `clip` writes everything an app needs in one call:

- **Formatted text** from markdown. Slack, Notes and Mail keep the bullets, bold, links, headings and code.
- **Files** (PDF, markdown, images, anything), as if you'd copied them in Finder.
- **Images** as pixels, for apps like Figma or Preview.
- **Another Mac's clipboard.** If your agents run on one Mac and you paste on another, `clip` copies the files over SSH and sets the clipboard there.

## Install

Needs macOS 13 or later and Swift (`xcode-select --install`).

```bash
curl -fsSL https://raw.githubusercontent.com/Pratham-commits-code/agent-clip/main/install.sh | bash
```

Or from a clone:

```bash
git clone https://github.com/Pratham-commits-code/agent-clip && cd agent-clip && ./install.sh
```

The installer builds `clip` into `~/.local/bin`, then asks two questions:

1. **Which Mac do you paste on?** Press Enter for this one. If agents run here but you paste on another Mac, give its SSH host. The installer checks the connection and installs `clip` there too. Passwordless SSH (keys) is required.
2. **Install the agent skill?** Asked for each of Claude Code (`~/.claude/skills`) and Codex (`~/.codex/skills`) if you have them. The skill tells agents when and how to use `clip`.

Re-run the installer any time to change your answers. To skip the questions, set them up front:

```bash
CLIP_REMOTE=my-laptop CLIP_SKILLS=yes ./install.sh   # CLIP_REMOTE=local for this Mac
```

## Usage

```bash
clip --md draft.md                                   # formatted text
cat <<'EOF' | clip --md -                            # or pipe it in
*Release*: v2 is out
- faster sync
- **new** export button
EOF
clip --md msg.md --file report.pdf --file shot.png   # text plus attachments
clip --image chart.png                               # image pixels
clip --html msg.html                                 # raw HTML
clip --text "plain fallback" --file notes.md         # plain text plus a file
clip --types                                         # show what's on the clipboard
```

`--file` and `--image` can be repeated. Each call replaces the whole clipboard.

To send to a different target than the configured one, use `--remote HOST` or `--local`.

With agents, just ask: "draft the release announcement for Slack with the changelog PDF attached and put it on my clipboard."

## How it works

`clip` is a single Swift file with no dependencies.

- **Markdown** is parsed with Apple's built-in parser and turned into HTML (read by Slack and browsers) and RTF (read by native apps). The markdown source is included as plain text for apps that want neither.
- **Files** go on the clipboard as file references. Each image or file is its own clipboard item, which a normal copy can't do from the command line.
- **Remote mode** sends the files as a tar over one SSH connection to `~/.cache/agent-clip/` on the other Mac, then runs `clip` there. The files have to stay until you paste, so each run deletes copies older than a day.
- **Settings** live in `~/.config/agent-clip/config`.

## Known limits

- It is not yet verified that Slack takes text and attachments from a single paste. If it only uploads the files, use two `clip` calls: one for the text, one for the files.
- Apps usually read only the first `--image`. To attach several images, use `--file` for each.
- Tables and nested block quotes come out as basic HTML. Slack doesn't render tables anyway.

## License

MIT
