import Foundation

/// The escape hatch: anything the other tools don't cover.
///
/// This is the one tool that runs arbitrary code, so it is `mutating` even for
/// commands that only read. The model cannot reliably tell `ls` from `rm -rf`
/// in a string it composed itself, so the human confirms every time — the
/// confirmation prompt shows the exact command before anything runs.
struct RunShellTool: Tool {
    let activityLabel = "Voert een commando uit"
    let name = "run_shell"
    let description = """
    Voert een shell-commando uit op deze Mac en geeft de uitvoer terug. \
    Gebruik dit alleen als geen enkele andere tool volstaat. \
    Houd commando's kort en beschrijf in je antwoord wat je hebt gedaan.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "command":{"type":"string","description":"Het commando, uitgevoerd met zsh."},
      "reason":{"type":"string","description":"Waarom dit commando nodig is. Wordt aan de gebruiker getoond ter goedkeuring."}},
     "required":["command"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let command = try arguments.requiredString("command")

        // Deliberately through a login shell: the point of this tool is that it
        // behaves like the user's own terminal, PATH and all.
        let result = try await Shell.capture("/bin/zsh", ["-lc", command], timeout: 60)

        let output = result.combined.isEmpty ? "(geen uitvoer)" : result.combined
        let truncated = output.count > 4000
            ? String(output.prefix(4000)) + "\n… (afgekapt)"
            : output
        return "exit \(result.status)\n\(truncated)"
    }
}
