import Foundation

/// Apple Notes, read straight from its own store.
///
/// Bodies live as **gzipped protobuf** in `ZICNOTEDATA.ZDATA`, so there is no
/// way to get at them with SQL alone. AppleScript can read notes but is far too
/// slow to search across 1500 of them — the same lesson the mail tool taught.
///
/// The extraction runs in one Python pass: open the store read-only, decompress,
/// strip the protobuf framing, filter. One subprocess for a whole search rather
/// than one per note.
private enum NotesStore {
    static var path: String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// Shared preamble: opens the store immutable and yields (title, text, modified).
    static let reader = """
    import sys, sqlite3, gzip, re, datetime
    db, query, limit, full = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == '1'
    con = sqlite3.connect('file:%s?immutable=1' % db, uri=True)
    rows = con.execute('''
        SELECT o.ZTITLE1, d.ZDATA, o.ZMODIFICATIONDATE1
        FROM ZICCLOUDSYNCINGOBJECT o
        JOIN ZICNOTEDATA d ON o.ZNOTEDATA = d.Z_PK
        WHERE o.ZTITLE1 IS NOT NULL
        ORDER BY o.ZMODIFICATIONDATE1 DESC
    ''').fetchall()

    def body(blob):
        if not blob:
            return ''
        try:
            raw = gzip.decompress(blob)
        except Exception:
            return ''
        # Protobuf framing is binary noise around readable runs; keep the runs.
        text = re.sub(rb'[^\\x20-\\x7e\\xc0-\\xff\\n]+', b' ', raw).decode('utf-8', 'ignore')
        return ' '.join(text.split())

    APPLE_EPOCH = 978307200
    needle = query.lower()
    shown = 0
    for title, blob, modified in rows:
        if shown >= limit:
            break
        text = body(blob)
        if needle and needle not in text.lower() and needle not in (title or '').lower():
            continue
        when = ''
        if modified:
            when = datetime.datetime.fromtimestamp(modified + APPLE_EPOCH).strftime('%Y-%m-%d')
        # The title is repeated as the first line of the body; drop the echo.
        snippet = text[len(title or ''):].strip() if text.startswith(title or '') else text
        snippet = snippet[:1200] if full else snippet[:180]
        print('%s | %s\\n    %s' % (title, when, snippet))
        shown += 1
    if shown == 0:
        print('__NONE__')
    """
}

struct SearchNotesTool: Tool {
    let activityLabel = "Zoekt in je notities"
    let name = "search_notes"
    let description = """
    Zoekt in Apple Notes op woorden in de titel of de tekst en geeft de treffers \
    met een fragment terug. Gebruik dit voor 'wat schreef ik over X' of \
    'heb ik ergens een notitie over Y'.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "query":{"type":"string","description":"Waar je op zoekt. Leeg laten geeft de meest recente notities."},
      "limit":{"type":"integer","description":"Maximaal aantal notities, standaard 8."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let query = arguments.string("query") ?? ""
        let limit = min(arguments.int("limit", default: 8), 25)

        guard let path = NotesStore.path else {
            throw ToolError.unavailable("""
            Geen toegang tot je notities. Zet NotchAI aan bij Systeeminstellingen → \
            Privacy en beveiliging → Volledige schijftoegang, en start de app opnieuw.
            """)
        }

        let result = try await Shell.capture(
            "/usr/bin/env",
            ["python3", "-c", NotesStore.reader, path, query, String(limit), "0"],
            timeout: 45)

        guard result.status == 0 else {
            if FullDiskAccess.looksDenied(result.combined) { throw FullDiskAccess.error("je notities") }
            throw ToolError.unavailable("Kon de notities niet lezen: \(result.combined.prefix(160))")
        }
        if result.stdout.contains("__NONE__") {
            return query.isEmpty ? "Geen notities gevonden." : "Geen notitie gevonden over '\(query)'."
        }
        return "Notities over '\(query.isEmpty ? "recent" : query)':\n" + result.stdout
    }
}

struct ReadNoteTool: Tool {
    let activityLabel = "Leest een notitie"
    let name = "read_note"
    let description = """
    Leest één notitie volledig, gezocht op titel. Gebruik dit nadat search_notes \
    de juiste notitie heeft gevonden en je de hele inhoud nodig hebt.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "title":{"type":"string","description":"De titel van de notitie, of een deel ervan."}},
     "required":["title"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let title = try arguments.requiredString("title")
        guard let path = NotesStore.path else {
            throw ToolError.unavailable("Geen toegang tot je notities (Volledige Schijftoegang).")
        }
        let result = try await Shell.capture(
            "/usr/bin/env",
            ["python3", "-c", NotesStore.reader, path, title, "1", "1"],
            timeout: 45)
        if FullDiskAccess.looksDenied(result.combined) { throw FullDiskAccess.error("je notities") }
        guard result.status == 0, !result.stdout.contains("__NONE__") else {
            throw ToolError.unavailable("Geen notitie gevonden met '\(title)' in de titel of tekst.")
        }
        return result.stdout
    }
}

/// Writing goes through AppleScript rather than the store.
///
/// The database is read-only by design — writing to it behind Notes' back would
/// desync iCloud. AppleScript is slow to *read* but perfectly fine to create a
/// single note, and it keeps Notes as the owner of its own data.
struct CreateNoteTool: Tool {
    let activityLabel = "Maakt een notitie"
    let name = "create_note"
    let description = """
    Maakt een nieuwe notitie in Apple Notes. Gebruik dit als de gebruiker iets \
    wil vastleggen of dicteren. Vat lange input samen tot iets dat later leesbaar is.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "title":{"type":"string","description":"Titel van de notitie."},
      "body":{"type":"string","description":"De inhoud."}},
     "required":["title","body"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let title = try arguments.requiredString("title")
        let body = arguments.string("body", default: "")

        // Notes takes HTML; the first line becomes the title in the UI.
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "<br>")
        }

        let script = """
        tell application "Notes"
            make new note at folder "Notes" of default account ¬
                with properties {body:"<div><b>\(escape(title))</b></div><div>\(escape(body))</div>"}
            return "ok"
        end tell
        """
        _ = try await Shell.osascript(script, timeout: 30)
        return "Notitie '\(title)' aangemaakt in Apple Notes."
    }
}
