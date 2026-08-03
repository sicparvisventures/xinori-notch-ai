import Foundation

/// Reads the inbox through Mail.app's AppleScript interface.
///
/// There is no read-only system API for mail, so this drives Mail.app directly.
/// The first call raises macOS's Automation consent prompt; until it is granted
/// every call fails with error -1743, which `Shell.osascript` turns into a
/// readable message rather than a raw AppleScript code.
struct ListMailTool: Tool {
    let name = "list_mail"
    let description = """
    Leest berichten uit de inbox van Mail.app: afzender, onderwerp en datum, \
    en optioneel het begin van de tekst. Gebruik dit voor 'check mijn mail' of \
    'heb ik nog ongelezen berichten'. Vat daarna zelf samen.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "unread_only":{"type":"boolean","description":"Alleen ongelezen berichten. Standaard true."},
      "limit":{"type":"integer","description":"Maximaal aantal berichten, standaard 10, maximaal 30."},
      "include_preview":{"type":"boolean","description":"Neem de eerste ~300 tekens van elk bericht mee."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let unreadOnly = arguments["unread_only"] as? Bool ?? true
        let limit = min(arguments.int("limit", default: 10), 30)
        let preview = arguments["include_preview"] as? Bool ?? false

        // Built as AppleScript rather than one message-at-a-time round trips:
        // each osascript call costs ~100ms, so a loop inside the script is an
        // order of magnitude faster than a loop outside it.
        let selector = unreadOnly
            ? "(messages of inbox whose read status is false)"
            : "(messages of inbox)"
        let previewLine = preview
            ? #"set body to (content of m) ; if length of body > 300 then set body to (text 1 thru 300 of body) ; set line to line & linefeed & body"#
            : ""

        let script = """
        tell application "Mail"
            set out to ""
            set msgs to \(selector)
            set total to count of msgs
            if total is 0 then return "Geen berichten gevonden."
            set shown to 0
            repeat with i from 1 to total
                if shown ≥ \(limit) then exit repeat
                set m to item i of msgs
                try
                    set line to (sender of m) & " | " & (subject of m) & " | " & ((date received of m) as string)
                    \(previewLine)
                    set out to out & line & linefeed & "---" & linefeed
                    set shown to shown + 1
                end try
            end repeat
            return "Totaal " & total & " berichten, hieronder de eerste " & shown & ":" & linefeed & out
        end tell
        """
        return try await Shell.osascript(script, timeout: 40)
    }
}
