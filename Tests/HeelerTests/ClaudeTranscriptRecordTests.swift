import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@Suite("Claude transcript records")
struct ClaudeTranscriptRecordTests {
    private static let probe = "claude/probe2-transcript.jsonl"

    private static func record(_ json: String, offset: UInt64 = 0) throws -> ClaudeRecord {
        guard case .record(let record) = ClaudeLine.decode(ChatLine(offset: offset, data: Data(json.utf8))) else {
            throw DecodeFailure(json: json)
        }
        return record
    }

    private struct DecodeFailure: Error, CustomStringConvertible {
        let json: String
        var description: String { "not a record: \(json)" }
    }

    @Test("Every line of the second probe decodes: 119 records and 47 metadata lines")
    func decodeAll() throws {
        let lines = try ChatFixture.lines(Self.probe)
        var records = 0
        var metadata = 0
        var invalid = 0
        for line in lines {
            switch ClaudeLine.decode(line) {
            case .record: records += 1
            case .metadata: metadata += 1
            case .invalid: invalid += 1
            }
        }
        #expect(lines.count == 166)
        #expect(records == 119)
        #expect(metadata == 47)
        #expect(invalid == 0)

        var reducer = ClaudeTranscriptReducer()
        reducer.append(lines)
        #expect(reducer.index.records.count == 119)
        #expect(reducer.index.title == "create-and-verify-probe-file")
        #expect(reducer.index.permissionMode == "default")
        #expect(reducer.index.model == "claude-sonnet-5-5")
        #expect(reducer.index.diagnostics == ChatTranscriptDiagnostics())
    }

    @Test("The newest main reply's effort is the session's; a sidechain's is not")
    func effortOfNewestReply() throws {
        func reply(_ uuid: String, effort: String, sidechain: Bool = false) -> String {
            #"{"type":"assistant","uuid":"\#(uuid)","parentUuid":null,"isSidechain":\#(sidechain),"effort":"\#(effort)","message":{"id":"m-\#(uuid)","model":"claude-fable-5-1","content":[{"type":"text","text":"ok"}]}}"#
        }
        #expect(try Self.record(reply("a1", effort: "high")).effort == "high")
        var reducer = ClaudeTranscriptReducer()
        reducer.append([
            ChatLine(offset: 0, data: Data(reply("a1", effort: "medium").utf8)),
            ChatLine(offset: 300, data: Data(reply("a2", effort: "high").utf8)),
            ChatLine(offset: 600, data: Data(reply("s1", effort: "low", sidechain: true).utf8)),
        ])
        #expect(reducer.index.effort == "high")
        // A newer reply without an effort clears it; a teammate's reply is not the session's.
        let haiku = #"{"type":"assistant","uuid":"h1","parentUuid":null,"message":{"id":"m-h1","model":"claude-haiku-5-5","content":[{"type":"text","text":"ok"}]}}"#
        let teammate = #"{"type":"assistant","uuid":"t1","parentUuid":null,"teamName":"crew","effort":"max","message":{"id":"m-t1","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}]}}"#
        reducer.append([ChatLine(offset: 900, data: Data(haiku.utf8)), ChatLine(offset: 1200, data: Data(teammate.utf8))])
        #expect(reducer.index.model == "claude-haiku-5-5")
        #expect(reducer.index.effort == nil)
        #expect(AgentSessionSettings(model: "claude-fable-5-1", permissionMode: nil, effort: "high").modelLine == "Fable 5.1 · high")
        #expect(AgentSessionSettings(model: "claude-fable-5-1", permissionMode: nil).modelLine == "Fable 5.1")
    }

    @Test("Metadata is last-wins by file position, whatever order lines arrive in")
    func metadataLastWins() throws {
        let lines = try ChatFixture.lines(Self.probe)
        // Through L87 the latest title is L63's and plan mode is on (L65).
        var head = ClaudeTranscriptReducer()
        head.append(Array(lines.prefix(87)))
        #expect(head.index.title == "c1.txt 文件创建")
        #expect(head.index.permissionMode == "plan")

        var reversed = ClaudeTranscriptReducer()
        reversed.append(Array(lines.dropFirst(87)))
        reversed.prepend(Array(lines.prefix(87)))
        #expect(reversed.index.title == "create-and-verify-probe-file")
        #expect(reversed.index.permissionMode == "default")
    }

    @Test("A typed prompt keeps its provenance and position")
    func typedPrompt() throws {
        let line = try #require(try ChatFixture.lines(Self.probe).first { $0.offset == 391 })
        guard case .record(let record) = ClaudeLine.decode(line) else {
            Issue.record("L5 is not a record")
            return
        }
        #expect(record.uuid == "e6fda38c-45bf-49c6-b0a2-5e1cf39cbef9")
        #expect(record.parentUUID == nil)
        #expect(record.kind == .user)
        #expect(record.byteOffset == 391)
        #expect(record.byteLength == line.length)
        #expect(record.promptSource == "typed")
        #expect(record.originKind == "human")
        #expect(record.sessionID == "e951205e-24af-4a5e-baa7-3ccbebd2de2c")
        #expect(record.texts == ["Use the Bash tool to run: touch c1.txt"])
    }

    @Test("Blocks of one API message are separate records sharing its id (L74, L76)")
    func splitMessage() throws {
        let lines = try ChatFixture.lines(Self.probe)
        let write = try #require(lines.first { $0.offset == 35529 })
        let search = try #require(lines.first { $0.offset == 38558 })
        guard case .record(let first) = ClaudeLine.decode(write), case .record(let second) = ClaudeLine.decode(search)
        else {
            Issue.record("L74 or L76 is not a record")
            return
        }
        #expect(first.messageID != nil)
        #expect(first.messageID == second.messageID)
        #expect(first.apiBlockIndex == 0)
        #expect(second.apiBlockIndex == 1)
        #expect(first.toolUses.map(\.name) == ["Write"])
        #expect(second.toolUses.map(\.name) == ["ToolSearch"])
        // L76 hangs off the result of L74's call, not off L74.
        #expect(second.parentUUID == "2791fe96-4b8f-4838-9796-2265181ea0bf")
    }

    @Test("A decline keeps its kind and the user's feedback (L26)")
    func declineFields() throws {
        let line = try #require(try ChatFixture.lines(Self.probe).first { $0.offset == 7319 })
        guard case .record(let record) = ClaudeLine.decode(line) else {
            Issue.record("L26 is not a record")
            return
        }
        let result = try #require(record.toolResults.first)
        #expect(result.toolUseID == "toolu_01TbgUciZNfX5qWyWVahrgJY")
        #expect(result.isError)
        #expect(record.toolResult?.denialKind == "user-rejected")
        #expect(record.toolResult?.userFeedback == "Do not create it; reply with the single word skipped")
    }

    @Test("A write keeps line counts and capped hunks, never the file")
    func writeReduction() throws {
        let big = String(repeating: "line of a large file\n", count: 5_000)
        let json = """
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result",\
            "tool_use_id":"toolu_w","content":"The file has been updated."}]},"toolUseResult":{"type":"update",\
            "filePath":"/w/big.txt","content":\(Self.quoted(big)),"originalFile":\(Self.quoted(big)),\
            "structuredPatch":[{"oldStart":3,"oldLines":2,"newStart":3,"newLines":3,"lines":[" keep","-old","+new","+added"]}]}}
            """
        let record = try Self.record(json)
        let result = try #require(record.toolResult?.result)
        #expect(result.diff == ChatDiffStats(added: 2, removed: 1))
        let hunk = ChatDiffHunk(oldStart: 3, oldLines: 2, newStart: 3, newLines: 3, lines: [" keep", "-old", "+new", "+added"])
        #expect(
            result.fileChanges
                == ChatFileChanges(files: [
                    ChatFileChange(path: "/w/big.txt", kind: .updated, added: 2, removed: 1, lineCount: 4, hunks: [hunk])
                ]))
        #expect(result.filePath == "/w/big.txt")
        #expect(record.blocks.count == 1)

        let created = try Self.record(
            """
            {"type":"user","uuid":"r2","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result",\
            "tool_use_id":"toolu_c","content":"File created"}]},"toolUseResult":{"type":"create","filePath":"/w/new.txt",\
            "content":\(Self.quoted(big)),"structuredPatch":[]}}
            """)
        let creation = try #require(created.toolResult?.result)
        #expect(creation.diff == ChatDiffStats(added: 5_000, removed: 0))
        let file = try #require(creation.fileChanges?.files.first)
        #expect(file.kind == .created)
        #expect(file.added == 5_000 && file.removed == 0 && file.lineCount == 5_000)
        #expect(file.heldLineCount == ChatFileChanges.rowLimits.lines)
        #expect(file.hunks.first?.lines.first == "+line of a large file")
        #expect(file.hunks.first?.newStart == 1 && file.hunks.first?.newLines == 5_000)
        #expect(!file.isComplete)
    }

    @Test("Images keep only their count")
    func imagesAreCounted() throws {
        let data = String(repeating: "iVBORw0KGgo", count: 2_000)
        let prompt = try Self.record(
            """
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":[{"type":"text","text":"What is this?"},\
            {"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(data)"}}]},"promptSource":"typed"}
            """)
        #expect(prompt.blocks == [.text("What is this?"), .image])
        #expect(prompt.imageCount == 1)

        let result = try Self.record(
            """
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result",\
            "tool_use_id":"toolu_r","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(data)"}}]}]}}
            """)
        #expect(result.toolResults == [
            ClaudeToolResult(toolUseID: "toolu_r", isError: false, content: ChatToolPreview(text: "", isTruncated: false, imageCount: 1))
        ])
    }

    @Test("A field of an unexpected type reads as absent")
    func lenientFields() throws {
        let record = try Self.record(
            """
            {"type":"user","uuid":"u1","parentUuid":7,"isMeta":"yes","promptSource":["typed"],"origin":"human",\
            "message":{"role":"user","content":[{"type":"text","text":"hi"},42,"loose",{"type":"tool_use","input":[]}]},\
            "toolDenialUnanswered":"stream-closed"}
            """)
        #expect(record.parentUUID == nil)
        #expect(!record.isMeta)
        #expect(record.promptSource == nil)
        #expect(record.originKind == nil)
        #expect(record.texts == ["hi"])
        #expect(record.blocks.count == 4)
        #expect(record.toolUses == [ClaudeToolUse(id: "", name: "", input: ClaudeToolInput())])
    }

    @Test("Unreadable lines are counted once each, never fatal")
    func diagnostics() {
        let texts = [
            #"not json"#,
            #"["an","array"]"#,
            #"{"no":"type"}"#,
            #"{"type":"user","parentUuid":null}"#,
            #"{"type":"brand-new-metadata","sessionId":"s"}"#,
            #"{"type":"future-record","uuid":"f1","parentUuid":null}"#,
            #"{"type":"system","subtype":"future_subtype","uuid":"y1","parentUuid":"f1"}"#,
        ]
        var offset: UInt64 = 0
        var lines: [ChatLine] = []
        for text in texts {
            lines.append(ChatLine(offset: offset, data: Data(text.utf8)))
            offset += UInt64(text.utf8.count + 1)
        }
        // A line longer than the framer keeps arrives as a prefix.
        lines.append(ChatLine(offset: offset, length: 20_000_000, data: Data(#"{"type":"user","uuid":"#.utf8)))

        var reducer = ClaudeTranscriptReducer()
        reducer.append(lines)
        reducer.append(lines)
        #expect(
            reducer.index.diagnostics
                == ChatTranscriptDiagnostics(
                    invalidLines: 4, oversizedLines: 1,
                    unknownRecordTypes: ["brand-new-metadata", "future-record", "system/future_subtype"]))
        // The unknown record stays on the tree so records below it are reachable.
        #expect(reducer.index.records["f1"]?.kind == .unknown("future-record"))
        #expect(reducer.index.records["y1"]?.parentUUID == "f1")
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Agent session settings", .serialized)
struct AgentSessionSettingsTests {
    @Test("A fresh Claude session shows live settings and keeps its confirmed mode while switching", arguments: [false, true])
    @MainActor func newConversationSettings(initiallyEmpty: Bool) async throws {
        let host = Host.fixture()
        let sessionID = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
        let info = AgentInfo(
            agentStatus: .idle, focused: false, paneID: "w1:p1", revision: 1,
            tabID: "t1", terminalID: "term-1", workspaceID: "w1", agent: "claude",
            agentSession: .init(agent: "claude", kind: .id, source: "herdr:claude", value: sessionID),
            cwd: "/home/dev/proj")
        let transport = ScriptedTransport(snapshot: .fixture(agents: [info]))
        let files = VirtualHostFiles()
        await files.makeDirectory("/home/dev/.claude/session-env/\(sessionID)")
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(info))
        let rule = String(repeating: "─", count: 93)
        // Claude Code 2.1.319's fresh-session screen, with no transcript yet.
        let screen = [
            " ▐▛███▛█   Claude Code v2.1.319",
            "▝▜██████▀  Sonnet 5.5 · Claude Ultra",
            " ▝▝   ▝▝   ~/proj", "", rule, "❯ ", rule,
            "  ⏵⏵ bypass permissions on (shift+tab to cycle)",
        ].joined(separator: "\r\n")
        if !initiallyEmpty { await transport.setPaneText(screen, paneID: info.paneID) }
        let console = ConsoleStore(chatCache: VolatileChatTranscriptCache()) { _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        console.setHosts([host])
        defer { console.setHosts([]) }
        await console.resume()
        var budget = PollBudget(.seconds(5))
        while console.agents.isEmpty, budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        let agent = try #require(console.agents.first)
        let chat = try #require(console.chatStore(for: agent, program: .claude))
        let suite = "new-claude-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agent.back-header-expanded")
        let controller = UIHostingController(rootView: NavigationStack {
            HerdrCoreChatTests.chatDetail(of: agent, console: console, defaults: defaults)
                .defaultAppStorage(defaults)
        })
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { window in
            if initiallyEmpty {
                var budget = PollBudget(.seconds(2))
                while await transport.agentReadCount == 0, budget.hasTimeLeft {
                    try await Task.sleep(for: .milliseconds(20))
                    budget.charge()
                }
                try #require(await transport.agentReadCount > 0)
                #expect(try await settingValue("Permission", in: window) == "Permission")
                // The screen finishes painting without another status event.
                await transport.setPaneText(screen, paneID: info.paneID)
            }
            var budget = PollBudget(.seconds(3))
            while budget.hasTimeLeft {
                if chat.conversation.phase == .unavailable(.awaitingFirstMessage(.claude)),
                    try await settingValue("Permission", in: window) == "bypass",
                    try await settingValue("Model", in: window) == "Sonnet 5.5" { break }
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            #expect(chat.conversation.phase == .unavailable(.awaitingFirstMessage(.claude)))
            #expect(try await settingValue("Permission", in: window) == "bypass")
            #expect(try await settingValue("Model", in: window) == "Sonnet 5.5")
            #expect(try await settingDisabled("Model", in: window) == false)

            try await HostedMenu.select("plan", labeled: "More", in: window)
            budget = PollBudget(.seconds(2))
            while try await settingValue("Permission", in: window) != "Switching from bypass", budget.hasTimeLeft {
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            // Stale terminal frames must leave the last confirmed mode visible.
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await settingValue("Permission", in: window) == "Switching from bypass")
            #expect(try await settingDisabled("Permission", in: window) == true)
            #expect(try await settingDisabled("Model", in: window) == false)
            // The model submenu keeps its value while a permission switch runs.
            if !initiallyEmpty {
                await transport.setPaneText(
                    screen.replacingOccurrences(of: "⏵⏵ bypass permissions on", with: "⏸ plan mode on"),
                    paneID: info.paneID)
            }
            // One case confirms the switch; the other times out on the old footer.
            let finalMode = initiallyEmpty ? "bypass" : "plan"
            budget = PollBudget(.seconds(4))
            while try await settingValue("Permission", in: window) != finalMode, budget.hasTimeLeft {
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            #expect(try await settingValue("Permission", in: window) == finalMode)
            #expect(try await settingDisabled("Permission", in: window) == false)
            #expect(try await settingDisabled("Model", in: window) == false)

            let reply = #"{"type":"assistant","uuid":"a1","parentUuid":null,"effort":"high","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"Hello"}]}}"#
            await files.write(Data((reply + "\n").utf8), at: "/home/dev/.claude/projects/-home-dev-proj/\(sessionID).jsonl")
            chat.retry()
            budget = PollBudget(.seconds(3))
            while try await settingValue("Model", in: window) != "Opus 5.5 · high", budget.hasTimeLeft {
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            #expect(try await settingValue("Model", in: window) == "Opus 5.5 · high")
        }
    }

    @MainActor
    private func settingValue(_ title: String, in window: UIWindow) async throws -> String? {
        let presented = try await HostedMenu.presentation(labeled: "More", in: window)
        let accessibility = accessibleElement(labeled: title, in: presented.controller.view)
        let item = HostedMenu.element(titled: title, in: presented.menu)
        let value = accessibility?.accessibilityValue ?? item?.subtitle
        presented.controller.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(20))
        return value
    }

    @MainActor
    private func settingDisabled(_ title: String, in window: UIWindow) async throws -> Bool? {
        let presented = try await HostedMenu.presentation(labeled: "More", in: window)
        let accessibility = accessibleElement(labeled: title, in: presented.controller.view)
        let item = HostedMenu.element(titled: title, in: presented.menu)
        let value = accessibility.map {
            $0.accessibilityTraits.contains(.notEnabled)
        } ?? item.flatMap(menuElementDisabled)
        presented.controller.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(20))
        return value
    }

    private func menuElementDisabled(_ element: UIMenuElement) -> Bool? {
        if let action = element as? UIAction { return action.attributes.contains(.disabled) }
        if let command = element as? UICommand { return command.attributes.contains(.disabled) }
        if let menu = element as? UIMenu {
            let states = menu.children.compactMap(menuElementDisabled)
            return states.isEmpty ? nil : states.allSatisfy { $0 }
        }
        return nil
    }

    @Test("An old transcript cannot offer bypass without a current launch opt-in")
    @MainActor func permissionMenuRequiresBypassAvailability() async throws {
        for available in [false, true] {
            var selected: String?
            let controller = UIHostingController(rootView: AgentPermissionModeLabel(
                settings: .init(model: "claude-opus-5-5", permissionMode: "bypassPermissions"),
                controls: .init(
                    isEnabled: true, allowsBypassPermissions: available,
                    setPermissionMode: { selected = $0 },
                    setModel: { _ in }, setEffort: { _ in }))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading))
            try await withTestWindow(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller
            ) { window in
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                let menus = try await HostedMenu.items(labeled: "Permission mode", in: window)
                let expected = available
                    ? ["manual", "accept edits", "plan", "bypass", "auto"]
                    : ["manual", "accept edits", "plan", "auto"]
                #expect(menus == [expected])
                try await HostedMenu.select("auto", labeled: "Permission mode", in: window)
                #expect(selected == "auto")
                try await HostedMenu.select("manual", labeled: "Permission mode", in: window)
                #expect(selected == "default")
            }
        }
    }

    @Test("The title offers the model grid and sends nothing until a cell is picked", arguments: ["claude-opus-5-5", "openai/gpt-5.6-luna"])
    @MainActor func modelAndEffortMenuSelections(currentModel: String) async throws {
        var model: String?
        var effort: String?
        let settings = AgentSessionSettings(model: currentModel, permissionMode: "default", effort: "high")
        let controls = AgentSessionControls(
            isEnabled: true, setPermissionMode: { _ in },
            setModel: { model = $0 },
            setEffort: { effort = $0 })
        let controller = UIHostingController(rootView: VStack {
            AgentDetailHeader(
                palette: .system, isExpanded: .constant(true), onBack: {},
                title: .init(title: "Review changes", kind: "claude", directory: "/home/dev/payments-api"),
                sessionSettings: settings, sessionControls: controls)
                .padding(.horizontal, 12)
            Spacer()
            AgentDetailStatusChrome(
                status: .idle, hostTelemetry: nil, session: settings,
                sessionControls: controls, chromeColorScheme: .light)
        })
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller
        ) { window in
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            #expect(accessibleElements(in: window).filter { $0.accessibilityLabel == "Agent settings" }.count == 1)
            // The title opens the model grid (its routing: `modelGridSelection`); laying out sends nothing.
            #expect(model == nil)
            #expect(effort == nil)
            let expectedLabel = currentModel == "claude-opus-5-5" ? "Opus 5.5 · high" : "openai/gpt-5.6-luna · high"
            #expect(accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue == expectedLabel)
        }
    }

    @Test("Bypass launch hints parse options, not arbitrary flag-looking text")
    func bypassLaunchOptions() {
        let allow = "--allow-dangerously-skip-permissions"
        for args in [
            [allow], ["--dangerously-skip-permissions"], ["--permission-mode", "bypassPermissions"],
            ["--permission-mode=bypassPermissions"], ["--permission-mode", "manual", allow],
            ["--tools", "", "--strict-mcp-config", "--settings", "", allow],
            ["--settings=", "--model=", allow], [allow, "--", "a prompt"],
        ] {
            #expect(ClaudePermissionMode.optsIntoBypass(argv: [""] + args), "\(args)")
        }
        for args in [
            [], ["--permission-mode", "manual"], ["--", allow], ["--system-prompt", allow],
            ["--settings", "--permission-mode=bypassPermissions"], [allow, "--restricted"],
            ["--permission-mode", "bypassPermissions", "--permission-mode=manual"],
            ["--permission-mode=bypassPermissions", "--permission-mode", "manual"],
            ["--unknown", allow], ["--tools", "", "-", allow], ["--allow-dangerously-skip-permissions=false"],
            ["some prompt quoting " + allow],
        ] {
            #expect(!ClaudePermissionMode.optsIntoBypass(argv: [""] + args), "\(args)")
        }
    }

    @Test("A rejected bypass hint lasts only for that process, and unknown never inherits a hint")
    @MainActor func bypassHintFollowsTheProcess() throws {
        let state = AgentSettingOverrides()
        func launch(_ start: String, optedIn: Bool = true) throws -> ClaudePermissionMode.Launch {
            try #require(ClaudePermissionMode.Launch(pid: "42", facts: .init(
                start: .value(start), argumentVector: .value(
                    optedIn ? ["claude", "--allow-dangerously-skip-permissions"] : ["claude"]))))
        }
        #expect(!state.allowsBypassPermissions)
        let original = try launch("100")
        state.refreshPermissionLaunch(original, liveMode: "default")
        #expect(state.allowsBypassPermissions)
        state.bypassWasMissingFromCycle()
        state.refreshPermissionLaunch(nil, liveMode: nil)
        state.refreshPermissionLaunch(original, liveMode: "plan")
        #expect(!state.allowsBypassPermissions)
        state.refreshPermissionLaunch(try launch("101"), liveMode: "default")
        #expect(state.allowsBypassPermissions)
        state.refreshPermissionLaunch(try launch("102", optedIn: false), liveMode: "default")
        #expect(!state.allowsBypassPermissions)
        state.refreshPermissionLaunch(nil, liveMode: "bypassPermissions")
        #expect(state.allowsBypassPermissions)
        state.refreshPermissionLaunch(nil, liveMode: nil)
        #expect(!state.allowsBypassPermissions)
    }

    @Test("A missing mode finishes one cycle at its starting mode, including delayed frames")
    @MainActor func permissionSwitchWaitsAndStopsAtTheOriginalMode() async {
        for hasBypass in [false, true] {
            let footers = ["? for shortcuts", "⏵⏵ accept edits on", "⏸ plan mode on"]
                + (hasBypass ? ["⏵⏵ bypass permissions on"] : []) + ["⏵⏵ auto mode on"]
            var index = 0
            var pending: Int?
            var staleFrames = 0
            var keys = 0
            let result = await ClaudePermissionMode.switchTo(
                "bypassPermissions", readScreen: {
                    if let next = pending {
                        if staleFrames > 0 { staleFrames -= 1 } else { index = next; pending = nil }
                    }
                    return Self.permissionScreen(footers[index])
                }, press: { _ in
                    #expect(pending == nil, "Never send a second key over an unconfirmed first key")
                    keys += 1
                    pending = (index + 1) % footers.count
                    staleFrames = 4
                }, mayContinue: { true }, pause: {})
            #expect(result.reachedTarget == hasBypass)
            #expect(result.completedCycle == !hasBypass)
            #expect(result.mode == (hasBypass ? "bypassPermissions" : "default"))
            #expect(keys == (hasBypass ? 3 : 4))
            #expect(index == (hasBypass ? 3 : 0))
        }
    }

    @Test("Missing feedback, a dialog or an interrupted switch never sends more keys")
    @MainActor func permissionSwitchStopsOnUncertainty() async {
        var keys = 0
        let stuck = await ClaudePermissionMode.switchTo(
            "bypassPermissions", readScreen: { Self.permissionScreen("? for shortcuts") },
            press: { _ in keys += 1 }, mayContinue: { true }, pause: {})
        #expect(keys == 1 && stuck.feedbackTimedOut && !stuck.completedCycle && !stuck.reachedTarget)
        keys = 0
        let interrupted = await ClaudePermissionMode.switchTo(
            "bypassPermissions", readScreen: { Self.permissionScreen("? for shortcuts") },
            press: { _ in keys += 1 }, mayContinue: { keys == 0 }, pause: {})
        #expect(keys == 1 && !interrupted.completedCycle && !interrupted.reachedTarget)
        keys = 0
        let unknown = await ClaudePermissionMode.switchTo(
            "default", readScreen: { ANSIScreenDecoder.decode("Connecting…") },
            press: { _ in keys += 1 }, mayContinue: { true }, pause: {})
        #expect(keys == 0 && !unknown.reachedTarget)
        let missingFooter = await ClaudePermissionMode.switchTo(
            "default", readScreen: { Self.permissionScreen("") },
            press: { _ in keys += 1 }, mayContinue: { true }, pause: {})
        #expect(keys == 0 && missingFooter.mode == nil && !missingFooter.reachedTarget)
    }

    private static func permissionScreen(_ footer: String) -> ANSIScreen {
        let rule = String(repeating: "─", count: 60)
        return ANSIScreenDecoder.decode([rule, "❯ ", rule, footer].joined(separator: "\r\n"))
    }

    @Test("Default mode is quiet without controls and an empty model has no subtitle")
    func quietWhenDefault() {
        #expect(AgentSessionSettings(model: nil, permissionMode: "default").notablePermissionMode == nil)
        #expect(AgentSessionSettings(model: "", permissionMode: nil).modelLine == nil)
        #expect(AgentSessionSettings(model: nil, permissionMode: "bypassPermissions").notablePermissionMode == "bypassPermissions")
        #expect(AgentSessionSettings.permissionTitle("bypassPermissions") == "bypass")
        #expect(AgentSessionSettings.permissionTitle("weird") == "weird")
    }

    @Test("Claude model ids shorten to the footer's name; others stay")
    func modelTitle() {
        #expect(AgentSessionSettings.modelTitle("claude-opus-5-5") == "Opus 5.5")
        #expect(AgentSessionSettings.modelTitle("claude-opus-5-5[1m]") == "Opus 5.5")
        #expect(AgentSessionSettings.modelTitle("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(AgentSessionSettings.modelTitle("claude-3-5-sonnet-20241022") == "claude-3-5-sonnet-20241022")
        // A model the Host's modelPicker names keeps that name; one it does not keeps its id.
        #expect(AgentSessionSettings.modelTitle("deepseek-v4.1-flash") == "deepseek-v4.1-flash")
        #expect(
            AgentSessionSettings.modelTitle(
                "deepseek-v4.1-flash",
                choices: [ClaudeModelChoice(id: "deepseek-v4.1-flash[1m]", title: "DeepSeek V4.1 Flash")])
                == "DeepSeek V4.1 Flash")
        #expect(AgentSessionSettings.model("deepseek-v4.1-flash", is: "deepseek-v4.1-flash[1m]"))
        #expect(AgentSessionSettings.modelTitle("mystery-1") == "mystery-1")
        #expect(AgentSessionSettings.modelTitle("sonnet") == "Sonnet")
        #expect(AgentSessionSettings.model("claude-opus-5-5[1m]", is: "opus"))
        #expect(!AgentSessionSettings.model("claude-opus-5-5", is: "sonnet"))
        #expect(AgentSessionSettings.modelChoices.allSatisfy { !AgentSessionSettings.model("openai/gpt-5.6-luna", is: $0.id) })
    }

    @Test("Only a pristine Claude welcome banner supplies a model before the first reply")
    func welcomeModel() throws {
        let ready = try ScreenFixture.text("claude-01-ready")
        #expect(AgentSessionSettings.welcomeModel(onScreen: ANSIScreenDecoder.decode(ready)) == "Sonnet 5.5")
        #expect(AgentSessionSettings.welcomeModel(onScreen: Self.permissionScreen("[Opus 5.5 high]")) == nil)
        let changed = ready.replacingOccurrences(of: "Claude Code", with: "Some reply quoting Claude Code")
        // A banner left above a command or reply cannot name the current model.
        let banner = [" ▐▛███▛█   Claude Code v2.1.319", "▝▜██████▀  Sonnet 5.5 · Claude Ultra", " ▝▝   ▝▝   ~/proj"]
        #expect(AgentSessionSettings.welcomeModel(onScreen: ScreenFixture.synthetic(banner + ["❯ /model opus", "Set model to Opus 5.5"])) == nil)
        #expect(AgentSessionSettings.welcomeModel(onScreen: ANSIScreenDecoder.decode(changed)) == nil)
    }

    @Test("The Host's modelPicker names the models the grid offers")
    func modelPickerOptions() {
        let settings = """
            {"theme": "dark", "modelPicker": {"options": [
              {"model": "deepseek-v4.1-flash[1m]", "label": "DeepSeek V4.1 Flash", "behavesAs": "claude-opus-5-5"},
              {"model": "k3.1-pro[1m]", "label": "Kimi K3.1 Pro"},
              {"model": "k3[1m]", "label": "Kimi K3"}
            ]}}
            """
        #expect(
            ClaudeModelPicker.options(in: Data(settings.utf8)) == [
                ClaudeModelChoice(id: "deepseek-v4.1-flash[1m]", title: "DeepSeek V4.1 Flash"),
                ClaudeModelChoice(id: "k3.1-pro[1m]", title: "Kimi K3.1 Pro"),
                ClaudeModelChoice(id: "k3[1m]", title: "Kimi K3"),
            ])
        // No modelPicker, broken JSON, other shapes: no models, no failure.
        #expect(ClaudeModelPicker.options(in: Data(#"{"theme":"dark"}"#.utf8)).isEmpty)
        #expect(ClaudeModelPicker.options(in: Data("not json".utf8)).isEmpty)
        #expect(ClaudeModelPicker.options(in: Data(#"{"modelPicker":{"options":"none"}}"#.utf8)).isEmpty)
        #expect(ClaudeModelPicker.options(in: Data(#"{"modelPicker":{"options":[{"label":"No model"}]}}"#.utf8)).isEmpty)
        // A missing or blank label names the model; a repeat keeps its first place.
        #expect(
            ClaudeModelPicker.options(in: Data(
                #"{"modelPicker":{"options":[{"model":"a[1m]"},{"model":"b[1m]","label":" "},{"model":"a[1m]","label":"A"}]}}"#
                    .utf8)) == [ClaudeModelChoice(id: "a[1m]", title: "a[1m]"), ClaudeModelChoice(id: "b[1m]", title: "b[1m]")])
        // A label the status line can show tells the model's name there.
        let choices = ClaudeModelPicker.options(in: Data(settings.utf8))
        #expect(AgentSessionSettings.modelTitle("deepseek-v4.1-flash", choices: choices) == "DeepSeek V4.1 Flash")
        #expect(AgentSessionSettings.model("deepseek-v4.1-flash", is: "deepseek-v4.1-flash[1m]"))
    }

    @Test("A Host's settings.json is read from its config root, within a size cap")
    func modelPickerRead() async throws {
        let files = VirtualHostFiles(home: "/home/dev")
        await files.write(
            #"{"modelPicker":{"options":[{"model":"qwen-4[1m]","label":"Qwen 4"}]}}"#,
            at: "/opt/claude/settings.json")
        #expect(
            try await ClaudeModelPicker.read(files: files.hostFiles(), configRoot: "/opt/claude") == [
                ClaudeModelChoice(id: "qwen-4[1m]", title: "Qwen 4")
            ])
        // No config root falls back to ~/.claude; a file there is too large.
        #expect(try await ClaudeModelPicker.read(files: files.hostFiles(), configRoot: nil).isEmpty)
        await files.write(
            #"{"modelPicker":{"options":[{"model":"x","label":"X"}]},"pad":""# + String(repeating: " ", count: 1 << 20)
                + "}",
            at: "/home/dev/.claude/settings.json")
        #expect(try await ClaudeModelPicker.read(files: files.hostFiles(), configRoot: nil).isEmpty)
    }

    @Test("The grid pages the Host's models by the first word of their labels")
    func modelGridPaging() {
        let choices = [
            ClaudeModelChoice(id: "deepseek-v4.1-flash[1m]", title: "DeepSeek V4.1 Flash"),
            ClaudeModelChoice(id: "k3.1-pro[1m]", title: "Kimi K3.1 Pro"),
            ClaudeModelChoice(id: "k3[1m]", title: "Kimi K3"),
        ]
        let pages = AgentModelPage.pages(choices)
        #expect(pages.map(\.name) == ["Claude", "DeepSeek", "Kimi"])
        #expect(pages[0].rows.map(\.rowTitle) == ["Opus", "Fable", "Sonnet", "Haiku"])
        #expect(pages[0].rows.map(\.id) == ["opus", "fable", "sonnet", "haiku"])
        #expect(pages[1].rows == [.init(id: "deepseek-v4.1-flash[1m]", rowTitle: "V4.1 Flash")])
        #expect(pages[2].rows.map(\.rowTitle) == ["K3.1 Pro", "K3"])
        // No Host models leaves Claude's page alone; a new vendor adds one, in order.
        #expect(AgentModelPage.pages([]).map(\.name) == ["Claude"])
        // A vendor the Host adds gets its own page; its first word names the page.
        let withQwen = AgentModelPage.pages(choices + [ClaudeModelChoice(id: "qwen-4[1m]", title: "Qwen 4")])
        #expect(withQwen.map(\.name) == ["Claude", "DeepSeek", "Kimi", "Qwen"])
        #expect(withQwen[3].rows == [.init(id: "qwen-4[1m]", rowTitle: "4")])
        // A one-word label names its page and its row alike.
        #expect(AgentModelPage.pages([ClaudeModelChoice(id: "glm[1m]", title: "GLM")]).last
            == AgentModelPage(name: "GLM", rows: [.init(id: "glm[1m]", rowTitle: "GLM")]))
    }

    @Test("The model grid routes one selection without reordering model and effort")
    func modelGridSelection() {
        #expect(AgentModelGrid.action(
            currentModel: "claude-opus-5-5", currentEffort: "high", model: "opus", effort: "high") == .noChange)
        #expect(AgentModelGrid.action(
            currentModel: "claude-opus-5-5", currentEffort: "high", model: "fable", effort: "high") == .model("fable"))
        #expect(AgentModelGrid.action(
            currentModel: "claude-opus-5-5", currentEffort: "high", model: "opus", effort: "max") == .effort("max"))
        #expect(AgentModelGrid.action(
            currentModel: "claude-opus-5-5", currentEffort: "high", model: "fable", effort: "max")
            == .modelAndEffort(model: "fable", effort: "max"))
        #expect(AgentModelGrid.action(
            currentModel: "deepseek-v4.1-flash", currentEffort: "high", model: "opus", effort: "high") == .model("opus"))
    }

    @Test("A switch's answer is the line below the newest echo of its command, not a recount")
    func switchOutcome() {
        func outcome(_ rows: [String]) -> AgentSessionSettings.Outcome {
            .init(of: "/model sonnet", done: "Set model to", kept: "Kept model as",
                  on: ANSIScreenDecoder.decode(rows.joined(separator: "\r\n")))
        }
        let before = outcome(["> /model sonnet", "  ⎿  Kept model as Opus 5.5", "> /model opus", "  ⎿  Set model to Opus 5.5", "> "])
        #expect(before.echoes == 1 && before.result == false)
        // Typed, not answered yet: the old Kept is not this command's.
        #expect(outcome(["> /model sonnet", "  ⎿  Kept model as Opus 5.5", "> "]).answered(since: before) == nil)
        // A full screen dropped both old lines, so no count of Set grows.
        let scrolled = outcome(["  ⎿  Set model to Opus 5.5", "> /model sonnet", "  ⎿  Set model to Sonnet 5.5", "> "])
        #expect(scrolled.value == "Sonnet 5.5")
        #expect(outcome(["> /model sonnet", "  ⎿  Set model to probe/small-model", "> "]).value == "probe/small-model")
        #expect(outcome(["> /model sonnet", "  ⎿  Set model to probe/small-model and saved as your default for new sessions", "> "]).value == "probe/small-model")
        #expect(before.value == nil)
        #expect(scrolled.answered(since: AgentSessionSettings.Outcome(
            of: "/model sonnet", done: "Set model to", kept: "Kept model as",
            on: ANSIScreenDecoder.decode("  ⎿  Set model to Opus 5.5\r\n> "))) == true)
        #expect(outcome(["> /model sonnet", "  ⎿  Kept model as Opus 5.5", "> /model sonnet", "  ⎿  Kept model as Opus 5.5"])
            .answered(since: before) == false)
    }

    @Test("A confirmed switch stands until the transcript records other values")
    @MainActor func overridesStandOverTheirTranscript() {
        let overrides = AgentSettingOverrides()
        let before: [String?] = ["default", "claude-opus-5-5", "high"]
        overrides.set(.model, "sonnet", over: before)
        overrides.set(.effort, "low", over: before)
        #expect(overrides.value(.model, over: before) == "sonnet")
        #expect(overrides.value(.effort, over: before) == "low")
        #expect(overrides.value(.permissionMode, over: before) == nil)
        // A newer reply records its own; the switch no longer stands over it.
        #expect(overrides.value(.model, over: ["default", "claude-sonnet-5-5", "low"]) == nil)
        // The footer's mode is not the reply's to replace.
        overrides.set(.permissionMode, "auto", over: before)
        #expect(overrides.value(.permissionMode, over: ["default", "claude-sonnet-5-5", "low"]) == "auto")
    }

    @Test("The permission mode is read off Claude Code's footer, not the conversation above it")
    func permissionModeOnScreen() throws {
        func screen(_ rows: [String]) -> ANSIScreen { ANSIScreenDecoder.decode(rows.joined(separator: "\r\n")) }
        let filler = Array(repeating: "", count: 6)
        #expect(AgentSessionSettings.permissionMode(onScreen: screen([])) == nil)
        #expect(AgentSessionSettings.permissionMode(onScreen: Self.permissionScreen("")) == nil)
        #expect(AgentSessionSettings.permissionMode(onScreen: try ScreenFixture.screen("claude-01-ready")) == "default")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["> hi", "", "  ⏵⏵ bypass permissions on (shift+tab to cycle)"])) == "bypassPermissions")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["  ⏸ plan mode on (shift+tab to cycle)"])) == "plan")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["  ⏵⏵ accept edits on"])) == "acceptEdits")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["plan mode on, said the reply"] + filler + ["  ? for shortcuts"])) == "default")
        // Claude Code 2.1.291 after a plan approval: four footer lines below the box.
        #expect(AgentSessionSettings.permissionMode(onScreen: try ScreenFixture.screen("claude-21-c6-after")) == "auto")
        let rule = String(repeating: "─", count: 40)
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["⏺ It printed bypass permissions on", rule, "> ", rule, "  ⏸ plan mode on (shift+tab to cycle)"])) == "plan")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["⏺ bypass permissions on", rule, "> ", rule, "  ? for shortcuts"])) == "default")
    }
}

/// The arc list's pure pieces: the tile color's hash and the status dot.
@Suite("Arc projects")
struct ArcProjectTests {
    @Test("A project's color follows its label, not the process's hash seed")
    func colorIsStableForALabel() {
        #expect(ArcProjectColor.color(for: "FreeRag") == ArcProjectColor.color(for: "FreeRag"))
        #expect(ArcProjectColor.index(for: "FreeRag") == ArcProjectColor.index(for: "FreeRag"))
        #expect(ArcProjectColor.color(for: "") == ArcProjectColor.color(for: ""))
        // Same bytes hashed twice in a fresh run would differ only if the
        // hash were seeded; a constant index pins the mapping itself.
        #expect(ArcProjectColor.index(for: "FreeRag") == ArcProjectColor.index(for: "FreeRag"))
    }

    @Test("Different labels spread across the palette")
    func colorsSpreadAcrossThePalette() {
        let labels = ["FreeRag", "FRS", "Heeler", "EBHD", "herdr-arc", "ios-app", "uurc-ios", "amazon"]
        let indexes = Set(labels.map(ArcProjectColor.index(for:)))
        #expect(indexes.count >= 4)
        #expect(indexes.allSatisfy { (0..<ArcProjectColor.palette.count).contains($0) })
    }

    @Test("The dot takes the worst status it sees")
    func lightPriority() {
        #expect(ArcProjectLight.light(for: [.idle]) == nil)
        #expect(ArcProjectLight.light(for: []) == nil)
        #expect(ArcProjectLight.light(for: [.done, .working]) == .done)
        #expect(ArcProjectLight.light(for: [.blocked, .done]) == .blocked)
        #expect(ArcProjectLight.light(for: [.working, .blocked, .done]) == .blocked)
        #expect(ArcProjectLight.light(for: [.working]) == .working)
        #expect(ArcProjectLight.light(for: [.idle, .working]) == .working)
        // Error is not Blocked: herdr reports a failure, not a waiting dialog.
        #expect(ArcProjectLight.light(for: [.error]) == nil)
    }
    private static func agent(
        _ pane: String, on host: Host, workspace: String, status: AgentStatus
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(
                terminalID: "term_\(pane)", kind: "claude", title: "",
                status: status, workspaceID: workspace, tabID: "\(workspace):t1", paneID: pane,
                cwd: "", revision: 1, name: nil),
            workspaceLabel: nil,
            repositoryCheckout: nil,
            lastOutputSnippet: nil)
    }

    @Test("Waiting lists Blocked, then Done, across Hosts in Host and herdr order")
    func waitingEntries() {
        let alpha = Host.fixture(name: "alpha")
        let beta = Host.fixture(name: "beta")
        let agents = [
            Self.agent("b1", on: beta, workspace: "w1", status: .blocked),
            Self.agent("a1", on: alpha, workspace: "w2", status: .done),
            Self.agent("a2", on: alpha, workspace: "w1", status: .blocked),
            Self.agent("a3", on: alpha, workspace: "w2", status: .working),
            Self.agent("a4", on: alpha, workspace: "w2", status: .blocked),
            Self.agent("a5", on: alpha, workspace: "w1", status: .error),
        ]
        let groups = ArcProjectGroup.groups(
            hosts: [alpha, beta], agents: agents,
            workspacesByHost: [
                alpha.id: [
                    ConsoleWorkspace(id: "w2", label: "Heeler", order: 1),
                    ConsoleWorkspace(id: "w1", label: "FRS", order: 0),
                ],
                beta.id: [ConsoleWorkspace(id: "w1", label: "EBHD", order: 0)],
            ])

        let blocked = ArcWaitingList.entries(groups, status: .blocked)
        #expect(blocked.map(\.agent.agent.paneID) == ["a2", "a4", "b1"])
        #expect(blocked.map(\.projectLabel) == ["FRS", "Heeler", "EBHD"])
        let done = ArcWaitingList.entries(groups, status: .done)
        #expect(done.map(\.agent.agent.paneID) == ["a1"])
        #expect(ArcWaitingList.entries([], status: .blocked).isEmpty)
    }

    @Test("Progress puts the most Blocked first, keeps herdr order on ties, and names who it waits on")
    func progressRows() {
        let host = Host.fixture(name: "alpha")
        let agents = [
            Self.agent("p1", on: host, workspace: "w1", status: .working),
            Self.agent("p2", on: host, workspace: "w2", status: .working),
            Self.agent("p3", on: host, workspace: "w2", status: .blocked),
            Self.agent("p4", on: host, workspace: "w3", status: .done),
            Self.agent("p5", on: host, workspace: "w5", status: .blocked),
            Self.agent("p6", on: host, workspace: "w5", status: .blocked),
        ]
        let groups = ArcProjectGroup.groups(
            hosts: [host], agents: agents,
            workspacesByHost: [
                host.id: [
                    ConsoleWorkspace(id: "w1", label: "A", order: 0),
                    ConsoleWorkspace(id: "w2", label: "B", order: 1),
                    ConsoleWorkspace(id: "w3", label: "C", order: 2),
                    ConsoleWorkspace(id: "w4", label: "D", order: 3),
                    ConsoleWorkspace(id: "w5", label: "E", order: 4),
                ]
            ])

        let rows = ArcProgressRow.rows(groups) { $0.agent.paneID }
        #expect(rows.map(\.project.label) == ["E", "B", "A", "C", "D"])
        // A Blocked Agent outranks a Working one for the subtitle.
        #expect(rows.map(\.subtitle) == ["p5", "p3", "p1", nil, nil])
        #expect(rows.map(\.blocked) == [2, 1, 0, 0, 0])
        #expect(rows.map(\.working) == [0, 1, 1, 0, 0])
        #expect(rows.map(\.done) == [0, 0, 0, 1, 0])
        #expect(rows.map(\.isEmpty) == [false, false, false, false, true])
    }

    @Test("A saved tab from before Hosts, Settings and Usage left the bar lands on Projects")
    func savedTabLandsOnAList() {
        #expect(ConsoleTab(saved: "agents") == .agents)
        #expect(ConsoleTab(saved: "terminals") == .terminals)
        for saved in ["hosts", "settings", "usage", "waiting", "progress", "", "nonsense"] {
            #expect(ConsoleTab(saved: saved) == .agents)
        }
        #expect(ConsoleTab.bar == [.agents, .waiting, .progress, .terminals])
        #expect(!ConsoleTab.waiting.isList)
        #expect(!ConsoleTab.progress.isList)
    }
    @Test("now.json reads each Agent's sentence, skipping blank and broken entries")
    func parsesAgentNow() {
        let data = Data(
            #"""
            {"agents": {
              "t5": {"fp": "780e9afca50416de", "now": "检查 FRS 后台进程运行状态", "now_ms": 1794280535230},
              "cn/t1g": {"fp": "x", "now": "  Trim me  ", "now_ms": null},
              "t9": {"now": "   "},
              "t10": {"fp": "no text"},
              "t11": "not an object"
            }}
            """#.utf8)
        let parsed = ArcAgentNow.parse(data)
        #expect(parsed["t5"]?.text == "检查 FRS 后台进程运行状态")
        #expect(parsed["t5"]?.at == Date(timeIntervalSince1970: 1_794_280_535.230))
        #expect(parsed["cn/t1g"]?.text == "Trim me")
        #expect(parsed["cn/t1g"]?.at == nil)
        #expect(parsed["t9"] == nil)
        #expect(parsed["t10"] == nil)
        #expect(parsed["t11"] == nil)
        // A file that is not the board's is no Agents, not a crash.
        #expect(ArcAgentNow.parse(Data("[]".utf8)).isEmpty)
        #expect(ArcAgentNow.parse(Data("not json".utf8)).isEmpty)
    }

    @Test("arc-board.json reads each space's asks, next and gates; missing parts stay empty")
    func parsesProjectBoard() {
        let data = Data(
            #"""
            {"spaces": {
              "spe78da": {"fp": "a", "at": 1794278848413, "ai": {
                "asks": [
                  {"kind": "decision", "title": "删不删半句", "detail": "需用户定。", "since": 1794278831079},
                  {"kind": "assist", "title": "签名交接", "detail": "", "since": null},
                  {"title": "  "},
                  {"kind": "unknown", "title": "assist by default"}
                ],
                "next": {"text": "发 test 通道", "eta": "~20 分钟"},
                "gates": [
                  {"ok": true, "title": "指定参数", "why": "已真机"},
                  {"ok": false, "title": "切会话卡顿", "why": "2 条测试红"},
                  {"ok": null, "title": "45 秒版", "why": "需用户看片"},
                  {"ok": true},
                  {"title": "no verdict"}
                ],
                "pr_notes": {"#954": {"packaged": "已在 b71 中修复"}}
              }},
              "sp3809": {"fp": "b", "ai": {"asks": [], "next": {"text": ""}, "gates": []}}
            }}
            """#.utf8)
        let parsed = ArcProjectBoard.parse(data)
        let board = parsed["spe78da"]
        #expect(board?.asks.map(\.kind) == [.decision, .assist, .assist])
        #expect(board?.asks.map(\.title) == ["删不删半句", "签名交接", "assist by default"])
        #expect(board?.asks[1].detail == nil)
        #expect(board?.asks[1].since == nil)
        #expect(board?.next == ArcProjectBoard.Next(text: "发 test 通道", eta: "~20 分钟"))
        // A gate with no verdict reads as one to check; one with no title
        // has nothing to show and drops.
        #expect(board?.gates.map(\.ok) == [true, false, nil, nil])
        #expect(board?.gates.map(\.title) == ["指定参数", "切会话卡顿", "45 秒版", "no verdict"])
        #expect(board?.at == Date(timeIntervalSince1970: 1_794_278_848.413))
        // A space with nothing to say is empty rather than absent.
        #expect(parsed["sp3809"]?.isEmpty == true)
        #expect(parsed["sp3809"]?.asks.isEmpty == true)
    }

    @Test("A board's space is the Workspace id without its prefix, on that Host only")
    func boardLookup() {
        #expect(ArcBoardLookup.spaceID(forWorkspace: "space-spe78da") == "spe78da")
        // A derived Workspace (d-…) is no space, and stays as it is.
        #expect(ArcBoardLookup.spaceID(forWorkspace: "d-1234") == "d-1234")

        let host = Host.fixture(name: "alpha")
        let other = Host.fixture(name: "beta")
        let board = ArcProjectBoard(asks: [], next: nil, gates: [], at: nil)
        let boards = [host.id: ["spe78da": board]]
        #expect(
            ArcBoardLookup.board(
                for: .init(hostID: host.id, workspaceID: "space-spe78da"), in: boards) != nil)
        #expect(
            ArcBoardLookup.board(
                for: .init(hostID: other.id, workspaceID: "space-spe78da"), in: boards) == nil)
        // Another Host's file never answers for this one's Agent.
        let now = [host.id: ["t5": ArcAgentNow(text: "now", at: nil)]]
        #expect(ArcAgentNowLookup.now(for: Self.agent("t5", on: host, workspace: "w1", status: .working), in: now)?.text == "now")
        #expect(ArcAgentNowLookup.now(for: Self.agent("t5", on: other, workspace: "w1", status: .working), in: now) == nil)
    }

    @Test("A gate reads as shipped, blocked or to check")
    func gateStates() {
        #expect(ArcProjectBoard.Gate(id: 0, ok: true, title: "a", why: nil).ok == true)
        #expect(ArcProjectBoard.Gate(id: 0, ok: false, title: "a", why: nil).ok == false)
        #expect(ArcProjectBoard.Gate(id: 0, ok: nil, title: "a", why: nil).ok == nil)
    }

    @Test("The All page names the first ask in red, else the working Agent")
    func allPageSubtitle() {
        let host = Host.fixture(name: "alpha")
        let agents = [
            Self.agent("p1", on: host, workspace: "w1", status: .working),
        ]
        let groups = ArcProjectGroup.groups(
            hosts: [host], agents: agents,
            workspacesByHost: [host.id: [ConsoleWorkspace(id: "w1", label: "A", order: 0)]])
        let row = ArcProgressRow.rows(groups) { $0.agent.paneID }[0]
        // Without a board the row keeps the Agent it is busy with.
        #expect(row.subtitle == "p1")
        let board = ArcProjectBoard(
            asks: [.init(id: 0, kind: .decision, title: "Ship it?", detail: nil, since: nil)],
            next: nil, gates: [], at: nil)
        #expect(
            ArcProgressSubtitle.text(for: row, board: board) == "Waiting: Ship it?")
        #expect(ArcProgressSubtitle.text(for: row, board: nil) == "p1")
    }

    @Test("The switcher lists busy projects first, most Blocked first, then each Host's others")
    func switcherSections() {
        let alpha = Host.fixture(name: "alpha")
        let beta = Host.fixture(name: "beta")
        let agents = [
            Self.agent("a1", on: alpha, workspace: "w1", status: .working),
            Self.agent("a2", on: alpha, workspace: "w2", status: .done),
            Self.agent("a3", on: alpha, workspace: "w3", status: .blocked),
            Self.agent("b1", on: beta, workspace: "w1", status: .blocked),
            Self.agent("b2", on: beta, workspace: "w1", status: .blocked),
            Self.agent("b3", on: beta, workspace: "w1", status: .working),
        ]
        let groups = ArcProjectGroup.groups(
            hosts: [alpha, beta], agents: agents,
            workspacesByHost: [
                alpha.id: [
                    ConsoleWorkspace(id: "w1", label: "FRS", order: 0),
                    ConsoleWorkspace(id: "w2", label: "Docs", order: 1),
                    ConsoleWorkspace(id: "w3", label: "Heeler", order: 2),
                    ConsoleWorkspace(id: "w4", label: "Quiet", order: 3),
                ],
                beta.id: [
                    ConsoleWorkspace(id: "w1", label: "EBHD", order: 0),
                    ConsoleWorkspace(id: "w2", label: "Rag", order: 1),
                ],
            ])

        let sections = ArcProjectMenu.sections(groups)
        #expect(sections.map(\.hostID) == [nil, alpha.id, beta.id])
        #expect(sections.map(\.title) == ["Active", "alpha", "beta"])
        // Two Blocked beat one; one Blocked beats none; ties keep herdr order.
        #expect(sections[0].items.map(\.project.label) == ["EBHD", "Heeler", "FRS"])
        #expect(sections[1].items.map(\.project.label) == ["Docs", "Quiet"])
        #expect(sections[2].items.map(\.project.label) == ["Rag"])
        #expect(sections[0].items.map(\.subtitle) == ["2 waiting · 1 running", "1 waiting", "1 running"])
        #expect(sections[1].items.map(\.subtitle) == [nil, nil])

        // Nothing busy: no leading section; a Host with every project busy
        // gets none either.
        let quiet = ArcProjectMenu.sections(
            ArcProjectGroup.groups(
                hosts: [alpha], agents: [],
                workspacesByHost: [alpha.id: [ConsoleWorkspace(id: "w1", label: "FRS", order: 0)]]))
        #expect(quiet.map(\.hostID) == [alpha.id])
        let busy = ArcProjectMenu.sections(
            ArcProjectGroup.groups(
                hosts: [alpha], agents: [Self.agent("a1", on: alpha, workspace: "w1", status: .working)],
                workspacesByHost: [alpha.id: [ConsoleWorkspace(id: "w1", label: "FRS", order: 0)]]))
        #expect(busy.map(\.hostID) == [nil])
    }

    @Test("The switcher's subtitle counts Blocked and working Agents, leaving zeros out")
    func switcherSubtitle() {
        #expect(ArcProjectMenu.subtitle(blocked: 1, working: 1) == "1 waiting · 1 running")
        #expect(ArcProjectMenu.subtitle(blocked: 3, working: 0) == "3 waiting")
        #expect(ArcProjectMenu.subtitle(blocked: 0, working: 2) == "2 running")
        #expect(ArcProjectMenu.subtitle(blocked: 0, working: 0) == nil)
    }

    @Test("AirBuild orders Blocked counts, then Working, and keeps at most two rows")
    func airBuildOrderingAndTruncation() {
        let host = Host.fixture(name: "alpha")
        let agents = [
            Self.agent("a1", on: host, workspace: "w1", status: .idle),
            Self.agent("b1", on: host, workspace: "w2", status: .working),
            Self.agent("c1", on: host, workspace: "w3", status: .blocked),
            Self.agent("d1", on: host, workspace: "w4", status: .blocked),
            Self.agent("d2", on: host, workspace: "w4", status: .blocked),
            Self.agent("e1", on: host, workspace: "w5", status: .done),
        ]
        let projects = ArcProjectGroup.groups(
            hosts: [host], agents: agents,
            workspacesByHost: [host.id: (1...5).map {
                ConsoleWorkspace(id: "w\($0)", label: ["A", "B", "C", "D", "E"][$0 - 1], order: $0)
            }]).flatMap(\.projects)

        let slots = AirBuildProjectLayout.slots(projects, columns: 2)
        #expect(slots.map(\.id) == ["\(host.id.uuidString)/w4", "\(host.id.uuidString)/w3", "\(host.id.uuidString)/w2", "all"])
        #expect(slots.last == .all(5))
        #expect(AirBuildProjectLayout.columns(for: 300) == 3)
        #expect(AirBuildProjectLayout.columns(for: 466) == 6)
    }

    @Test("AirBuild shows All only when the two rows cannot hold every project")
    func airBuildAllSlotCondition() {
        let host = Host.fixture(name: "alpha")
        let workspaces = (1...4).map {
            ConsoleWorkspace(id: "w\($0)", label: "P\($0)", order: $0)
        }
        let projects = ArcProjectGroup.groups(
            hosts: [host], agents: [], workspacesByHost: [host.id: workspaces]
        ).flatMap(\.projects)
        #expect(AirBuildProjectLayout.slots(projects, columns: 2).map(\.id) == projects.map(\.id.storedText))
        #expect(AirBuildProjectLayout.slots(projects, columns: 1).last == .all(4))
        #expect(AirBuildProjectLayout.slots(projects, columns: 1).count == 2)
    }

    @Test("AirBuild badges count Blocked, show Done green, and leave Working unbadged")
    func airBuildBadgeRules() {
        let host = Host.fixture(name: "alpha")
        func project(_ workspace: String, _ statuses: [AgentStatus]) -> ArcProjectGroup.Project {
            ArcProjectGroup.Project(
                id: .init(hostID: host.id, workspaceID: workspace), label: workspace,
                agents: statuses.enumerated().map {
                    Self.agent("p\($0.offset)", on: host, workspace: workspace, status: $0.element)
                })
        }
        #expect(AirBuildProjectLayout.badge(for: project("a", [.done, .blocked, .blocked])) == .blocked(2))
        #expect(AirBuildProjectLayout.badge(for: project("b", [.done, .working])) == .done)
        #expect(AirBuildProjectLayout.badge(for: project("c", [.working, .idle])) == nil)
    }

    @Test("v2 counts every Blocked conversation across projects")
    func airBuildWaitingSummary() {
        let alpha = Host.fixture(name: "alpha")
        let beta = Host.fixture(name: "beta")
        let agents = [
            Self.agent("a1", on: alpha, workspace: "w1", status: .working),
            Self.agent("a2", on: alpha, workspace: "w2", status: .blocked),
            Self.agent("b1", on: beta, workspace: "w1", status: .done),
            Self.agent("b2", on: beta, workspace: "w2", status: .blocked),
        ]
        #expect(AirBuildWaitingSummary.blocked(agents).map(\.id) == [agents[1].id, agents[3].id])
        #expect(AirBuildWaitingSummary.blocked([]).isEmpty)
    }

    @Test("v2 maps the status lamp to its color, shape and spoken state")
    func airBuildStatusLamps() {
        #expect(AirBuildStatusLamp(status: .working).rgb == 0xFF9F0A)
        #expect(AirBuildStatusLamp(status: .blocked).rgb == 0xBF5AF2)
        #expect(AirBuildStatusLamp(status: .done).rgb == 0x30D158)
        #expect(AirBuildStatusLamp(status: .idle).rgb == 0x8E8E93)
        #expect(AirBuildStatusLamp(status: .working, isHostConnected: false) == .disconnected)
        #expect(AirBuildStatusLamp(status: .blocked, isHostConnected: false).isHollow)
        #expect(AirBuildStatusLamp(status: .working).accessibilityLabel == "Running")
        #expect(AirBuildStatusLamp(status: .blocked).accessibilityLabel == "Waiting on You")
        #expect(AirBuildStatusLamp(status: .done).accessibilityLabel == "Done")
        #expect(AirBuildStatusLamp(status: .idle).accessibilityLabel == "Idle")
    }

    @Test("v2 keeps the chat menu in four fixed groups")
    func airBuildMenuGroups() {
        #expect(AirBuildChatMenuGroup.allCases == [.activity, .session, .navigation, .destructive])
        #expect(AirBuildChatMenuPolicy.items(in: .activity) == [
            .agentTerminal, .openTerminal, .changes, .progress,
        ])
        #expect(AirBuildChatMenuPolicy.items(in: .session) == [
            .model, .permission, .newAgent, .skills, .snippets,
        ])
        #expect(AirBuildChatMenuPolicy.items(in: .navigation) == [
            .goTo, .rename, .renameAgent, .renameWorkspace, .worktreeDetails,
        ])
        #expect(AirBuildChatMenuPolicy.items(in: .destructive) == [.close])
    }

    @Test("v2 keeps the vertical bar limited to global actions")
    func airBuildVerticalBarItems() {
        #expect(AirBuildVerticalBarItem.allCases == [.workspace, .terminal, .account, .settings])
        #expect(AirBuildVerticalBarItem.workspace.systemImage == "square.grid.2x2")
        #expect(AirBuildVerticalBarItem.terminal.systemImage == "terminal")
        #expect(AirBuildVerticalBarItem.settings.systemImage == "gearshape")
    }

    @Test("v2 formats the running clock as minutes and seconds")
    func airBuildRunningClock() {
        let start = Date(timeIntervalSince1970: 100)
        #expect(AirBuildRunningClock.text(startedAt: start, now: start) == "0:00")
        #expect(AirBuildRunningClock.text(startedAt: start, now: start.addingTimeInterval(42)) == "0:42")
        #expect(AirBuildRunningClock.text(startedAt: start, now: start.addingTimeInterval(125)) == "2:05")
        #expect(AirBuildRunningClock.text(startedAt: start, now: start.addingTimeInterval(-2)) == "0:00")
    }
}
