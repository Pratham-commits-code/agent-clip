// clip: put rich, multi-item content on the macOS clipboard in one shot.
// Install: ./install.sh (builds, installs, and walks through configuration)
import AppKit

let usage = """
usage: clip [--md FILE|-] [--html FILE|-] [--text TEXT] [--file PATH]... [--image PATH]...
       clip --types     list what is on the clipboard now
       clip --remote HOST ...   copy files over SSH and set HOST's clipboard (HOST needs clip installed)
       clip --local ...         use this Mac's clipboard even if a remote is configured

  The default target comes from ~/.config/agent-clip/config (remote=HOST), written by install.sh.

  --md     markdown, rendered to rich text (HTML + RTF) so Slack/Notes/Mail keep formatting
  --html   raw HTML fragment, same treatment as --md
  --text   plain-text fallback (defaults to the markdown source or text derived from HTML)
  --file   attach a file (pdf, md, png, ...) as a file reference; repeatable
  --image  put image pixels on the clipboard (for apps that want image data); repeatable
"""

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func readSource(_ path: String) -> String {
    if path == "-" { return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { die("clip: cannot read \(path)") }
    return s
}

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func tags(_ kind: PresentationIntent.Kind) -> (open: String, close: String) {
    switch kind {
    case .paragraph: return ("<p>", "</p>")
    case .header(let level): return ("<h\(level)>", "</h\(level)>")
    case .orderedList: return ("<ol>", "</ol>")
    case .unorderedList: return ("<ul>", "</ul>")
    case .listItem: return ("<li>", "</li>")
    case .codeBlock: return ("<pre><code>", "</code></pre>")
    case .blockQuote: return ("<blockquote>", "</blockquote>")
    case .thematicBreak: return ("<hr>", "")
    case .table: return ("<table>", "</table>")
    case .tableHeaderRow, .tableRow: return ("<tr>", "</tr>")
    case .tableCell: return ("<td>", "</td>")
    @unknown default: return ("", "")
    }
}

// Skip <p> directly inside <li> so Slack renders tight bullets, not spaced paragraphs.
func tags(_ blocks: [PresentationIntent.IntentType], _ i: Int) -> (open: String, close: String) {
    if case .paragraph = blocks[i].kind, i > 0, case .listItem = blocks[i - 1].kind { return ("", "") }
    return tags(blocks[i].kind)
}

// Foundation parses the markdown; we only walk its block tree and emit HTML.
func markdownToHTML(_ md: String) -> String {
    guard let doc = try? AttributedString(markdown: md, options: .init(interpretedSyntax: .full)) else {
        die("clip: invalid markdown")
    }
    var html = ""
    var open: [PresentationIntent.IntentType] = [] // outermost first
    for run in doc.runs {
        let path = Array((run.presentationIntent?.components ?? []).reversed())
        var shared = 0
        while shared < open.count, shared < path.count, open[shared] == path[shared] { shared += 1 }
        for i in (shared..<open.count).reversed() { html += tags(open, i).close }
        for i in shared..<path.count { html += tags(path, i).open }
        open = path

        var s = esc(String(doc[run.range].characters))
        if let i = run.inlinePresentationIntent {
            if i.contains(.lineBreak) { s = "<br>" }
            if i.contains(.code) { s = "<code>\(s)</code>" }
            if i.contains(.emphasized) { s = "<em>\(s)</em>" }
            if i.contains(.stronglyEmphasized) { s = "<strong>\(s)</strong>" }
            if i.contains(.strikethrough) { s = "<s>\(s)</s>" }
        }
        if let url = run.link { s = "<a href=\"\(esc(url.absoluteString))\">\(s)</a>" }
        html += s
    }
    for i in open.indices.reversed() { html += tags(open, i).close }
    return html
}

func existingFile(_ path: String) -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).absoluteURL.standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { die("clip: no such file \(path)") }
    return url
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// Agents run on one Mac, the user pastes on another: ship referenced files to HOST in a tar
// over the same SSH connection, rewrite paths, and run clip there so HOST's clipboard is set.
func runRemote(host: String, _ args: [String]) -> Never {
    let dir = ".cache/agent-clip/\(UUID().uuidString)" // relative to the remote home
    var sources: [URL] = [], remoteArgs: [String] = [], rest = args[...]
    while let flag = rest.popFirst() {
        remoteArgs.append(flag)
        guard flag != "--types" else { continue }
        guard var value = rest.popFirst() else { die("clip: \(flag) needs a value") }
        if ["--md", "--html", "--file", "--image"].contains(flag) {
            if value == "-" {
                value = NSTemporaryDirectory() + "clip-stdin-\(UUID().uuidString).txt"
                FileManager.default.createFile(atPath: value, contents: FileHandle.standardInput.readDataToEndOfFile())
            }
            let url = existingFile(value)
            if sources.contains(where: { $0.lastPathComponent == url.lastPathComponent }) {
                die("clip: two files named \(url.lastPathComponent), rename one")
            }
            sources.append(url)
            value = "\(dir)/\(url.lastPathComponent)"
        }
        remoteArgs.append(value)
    }

    // Files must outlive the paste, so keep them and prune anything older than a day.
    let script = "mkdir -p \(dir) && tar -xf - -C \(dir) && find .cache/agent-clip -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} + ; "
        + "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" clip --local " + remoteArgs.map(shellQuote).joined(separator: " ")
    let ssh = Process()
    ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    ssh.arguments = ["-o", "BatchMode=yes", host, script]
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    // -L ships symlink targets; COPYFILE_DISABLE stops macOS adding ._ metadata files.
    tar.arguments = ["-cLf", "-"] + sources.flatMap { ["-C", $0.deletingLastPathComponent().path, $0.lastPathComponent] }
    tar.environment = ["COPYFILE_DISABLE": "1"]
    if sources.isEmpty { tar.arguments = ["-cf", "-", "-T", "/dev/null"] }
    let pipe = Pipe()
    tar.standardOutput = pipe
    ssh.standardInput = pipe
    do { try tar.run(); try ssh.run() } catch { die("clip: \(error.localizedDescription)") }
    tar.waitUntilExit()
    ssh.waitUntilExit()
    exit(tar.terminationStatus != 0 ? tar.terminationStatus : ssh.terminationStatus)
}

let pb = NSPasteboard.general
var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") { print(usage); exit(args.isEmpty ? 1 : 0) }

func configuredRemote() -> String? {
    let path = NSHomeDirectory() + "/.config/agent-clip/config"
    guard let config = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let host = config.split(separator: "\n").first { $0.hasPrefix("remote=") }?.dropFirst("remote=".count)
    return host.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
}

if let l = args.firstIndex(of: "--local") {
    args.remove(at: l)
} else if let r = args.firstIndex(of: "--remote") {
    guard r + 1 < args.count else { die("clip: --remote needs a host") }
    let host = args[r + 1]
    args.removeSubrange(r...(r + 1))
    runRemote(host: host, args)
} else if let host = configuredRemote() {
    runRemote(host: host, args)
}

if args == ["--types"] {
    for (n, item) in (pb.pasteboardItems ?? []).enumerated() {
        print("item \(n): " + item.types.map(\.rawValue).joined(separator: ", "))
    }
    exit(0)
}

var html: String?, text: String?, files: [URL] = [], images: [NSImage] = []
while !args.isEmpty {
    let flag = args.removeFirst()
    guard !args.isEmpty else { die("clip: \(flag) needs a value\n\n\(usage)") }
    let value = args.removeFirst()
    switch flag {
    case "--md": let md = readSource(value); html = markdownToHTML(md); text = text ?? md
    case "--html": html = readSource(value)
    case "--text": text = value
    case "--file": files.append(existingFile(value))
    case "--image":
        guard let img = NSImage(contentsOf: existingFile(value)) else { die("clip: not an image \(value)") }
        images.append(img)
    default: die("clip: unknown flag \(flag)\n\n\(usage)")
    }
}

guard html != nil || text != nil || !files.isEmpty || !images.isEmpty else { die(usage) }

var objects: [NSPasteboardWriting] = []
if html != nil || text != nil {
    let item = NSPasteboardItem()
    if let html {
        // RTF for native apps (Notes, Mail, TextEdit); browsers/Electron (Slack) read the HTML.
        let rich = try? NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
        item.setString(html, forType: .html)
        if let rich, let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length)) { item.setData(rtf, forType: .rtf) }
        text = text ?? rich?.string
    }
    item.setString(text ?? "", forType: .string)
    objects.append(item)
}
for url in files {
    let item = NSPasteboardItem()
    item.setString(url.absoluteString, forType: .fileURL)
    objects.append(item)
}
for image in images {
    let item = NSPasteboardItem()
    if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    if let png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) {
        item.setData(png, forType: .png)
    }
    objects.append(item)
}

pb.clearContents()
guard pb.writeObjects(objects) else { die("clip: failed to write clipboard") }
// Read back before exiting: without this, file-url items can be dropped when the process exits fast.
// ponytail: fixed delay. If this process exits right after writing, file-url items are
// sometimes dropped (seen with CopyClip/Raycast running). 0.2s was reliable in testing;
// raise it if items still go missing.
Thread.sleep(forTimeInterval: 0.2)
let written = pb.pasteboardItems?.map { $0.types.map(\.rawValue).sorted() } ?? []
guard written.count == objects.count, !written.contains([]) else { die("clip: clipboard write did not stick") }
