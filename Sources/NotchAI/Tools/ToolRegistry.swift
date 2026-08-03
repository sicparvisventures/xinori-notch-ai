import Foundation

/// Everything the model is allowed to do to this Mac.
///
/// Adding a tool here is the only step needed to expose it: the schemas are
/// derived, and the confirmation gate follows from each tool's own `risk`.
struct ToolRegistry: Sendable {
    static let shared = ToolRegistry()

    let tools: [any Tool] = [
        SystemInfoTool(),
        SearchFilesTool(),
        FrontmostAppTool(),
        ListMailTool(),
        ListCalendarTool(),
        ListScheduledJobsTool(),
        ScheduleJobTool(),
        ListDirectoryTool(),
        ReadFileTool(),
        ReadSpreadsheetTool(),
        WriteFileTool(),
        TrashTool(),
        OpenPathTool(),
        ListAppsTool(),
        ControlAppTool(),
        RunShellTool(),
    ]

    var schemas: [ToolSchema] { tools.map(\.schema) }

    func tool(named name: String) -> (any Tool)? {
        tools.first { $0.name == name }
    }

    /// Run a call that has already cleared confirmation.
    ///
    /// A failing tool returns its error as text rather than throwing: the model
    /// needs to see *why* something failed so it can try another route, and a
    /// thrown error would abort the whole turn instead.
    func run(_ call: ToolCall) async -> String {
        guard let tool = tool(named: call.name) else {
            return ToolError.unknownTool(call.name).localizedDescription
        }
        do {
            Log.write("tool: \(call.summary)")
            return try await tool.run(arguments: call.arguments)
        } catch {
            Log.write("tool: \(call.name) failed — \(error.localizedDescription)")
            return "Fout: \(error.localizedDescription)"
        }
    }
}
