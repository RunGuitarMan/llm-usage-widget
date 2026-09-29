import Foundation
import SQLite3

private struct TranscriptCheckFailure: Error, CustomStringConvertible { var description: String }

@MainActor enum TranscriptChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TranscriptCheckFailure(description: message) }
    }
    private static func decode(_ source: String, _ lines: String) throws -> [TranscriptEvent] {
        var decoder = TranscriptDecoder(source: source)
        for line in lines.split(separator: "\n") {
            decoder.append(try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
        }
        return decoder.finish()
    }
    private static func session(_ source: String, _ id: String = "session-a") -> UsageSession {
        .init(id: "test", models: [], usage: .zero, lastActivity: nil, agent: source, originalID: id)
    }
    static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("Chat: Codex dual streams retain repeated messages and tool results") {
            let events = try decode("codex", #"""
            {"type":"event_msg","payload":{"type":"user_message","message":"again","local_images":[]}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"again"}]}}
            {"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1","input":"pwd"}}
            {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"/example"}}
            {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}
            {"type":"event_msg","payload":{"type":"agent_message","message":"Done"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"again"}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"again"}]}}
            """#)
            try require(events.count == 4, "Duplicate streams were shown twice or repeated prompts were lost")
            try require(events.map(\.kind) == [.user, .tool, .assistant, .user], "Timeline order changed")
            try require(events[1].input == "pwd" && events[1].output == "/example" && events[1].hasResult, "Call/result not linked")
            try require(events[0].raw.contains("local_images"), "Secondary stream metadata lost")
        }
        await check("Chat: Claude mixed content, parallel tools, errors, and attachments") {
            let events = try decode("claude", #"""
            {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Read both files"},{"type":"image","source":{"type":"base64","data":"example"}}]}}
            {"type":"assistant","message":{"role":"assistant","model":"test-model","content":[{"type":"text","text":"Reading"},{"type":"tool_use","id":"a","name":"Read","input":{"file_path":"a"}},{"type":"tool_use","id":"b","name":"Read","input":{"file_path":"b"}}]}}
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"missing","is_error":true},{"type":"tool_result","tool_use_id":"a","content":""}]}}
            """#)
            try require(events.count == 4 && events[0].text.contains("Изображение"), "Attachments or message roles missing")
            try require(events[1].model == "test-model", "Model lost")
            try require(events[2].hasResult && events[2].output.isEmpty, "Empty result confused with pending tool")
            try require(events[3].isError && events[3].output == "missing", "Parallel result assigned to wrong call")
            try require(Set(events.map(\.id)).count == events.count, "Duplicate UI IDs")
        }
        await check("Chat: Gemini calls, Amp, Droid, pi, Qwen, Codebuff, OpenClaw formats") {
            let gemini = try decode("gemini", #"""
            {"type":"user","content":"Check"}
            {"type":"gemini","content":"Looking","toolCalls":[{"id":"g1","name":"read_file","args":{"path":"a"},"result":"ok"}]}
            """#)
            try require(gemini.map(\.kind) == [.user,.assistant,.tool] && gemini[2].output == "ok", "Gemini call lost")
            for source in ["amp", "codebuff", "qwen"] {
                let events = try decode(source, #"{"role":"assistant","content":[{"type":"text","text":"Response"}]}"#)
                try require(events.first?.text == "Response", "Direct message missing: \(source)")
            }
            for source in ["droid", "pi", "openclaw"] {
                let events = try decode(source, #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Nested"}]}}"#)
                try require(events.first?.text == "Nested", "Nested message missing: \(source)")
            }
        }
        await check("Chat: Copilot and Kimi tool events are readable") {
            let copilot = try decode("copilot", #"""
            {"type":"user.message","data":{"content":"hello"}}
            {"type":"tool.execution_start","data":{"toolCallId":"t1","toolName":"shell","arguments":{"command":"pwd"}}}
            {"type":"tool.execution_complete","data":{"toolCallId":"t1","success":true,"result":{"content":"/example"}}}
            {"type":"assistant.message","data":{"content":"done"}}
            """#)
            try require(copilot.map(\.kind) == [.user,.tool,.assistant] && copilot[1].output == "/example", "Copilot events not linked")
            let kimi = try decode("kimi", #"""
            {"message":{"type":"TurnBegin","payload":{"user_input":"hello"}}}
            {"message":{"type":"ContentPart","payload":{"type":"text","text":"hel"}}}
            {"message":{"type":"ContentPart","payload":{"type":"text","text":"lo"}}}
            """#)
            try require(kimi.count == 2 && kimi[1].text == "hello", "Kimi chunks not assembled")
            let grok = try decode("grok", #"""
            {"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hello"}}
            {"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hel"}}
            {"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}
            {"sessionUpdate":"tool_call","toolCallId":"t1","title":"shell","rawInput":{"command":"pwd"}}
            {"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","rawOutput":"/example"}
            """#)
            try require(grok.count == 3 && grok[1].text == "hello" && grok[2].output == "/example", "Grok chunks or tool result lost")
        }
        await check("Chat: unknown and encrypted records remain accessible") {
            let events = try decode("codex", #"""
            {"type":"response_item","payload":{"type":"reasoning","encrypted_content":"opaque-data"}}
            {"type":"future-event","payload":{"extra":"preserved"}}
            """#)
            let transcript = SessionTranscript(events: events)
            try require(events.allSatisfy { $0.kind == .context }, "Technical data shown as a reply")
            try require(transcript.exportText.contains("opaque-data") && transcript.exportText.contains("preserved"), "Raw record lost")
            let context = try decode("codex", #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>environment details</environment_context>"}]}}"#)
            try require(context.first?.kind == .context && context.first?.raw.contains("environment details") == true, "Environment pollutes chat or is lost")
        }
        await check("Chat: discovery uses exact identity, project and configured roots") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = root.appendingPathComponent("projects/project-a")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"type":"user","message":{"role":"user","content":"correct session"}}"#.write(to: dir.appendingPathComponent("session-a.jsonl"), atomically: true, encoding: .utf8)
            try #"{"type":"user","message":{"role":"user","content":"session-a appears in unrelated content"}}"#.write(to: dir.appendingPathComponent("session-other.jsonl"), atomically: true, encoding: .utf8)
            let service = TranscriptService(home: root, environment: ["CLAUDE_CONFIG_DIR": root.path])
            let result = try await service.load(session: session("claude"))
            try require(result.messageCount == 1 && result.events[0].text == "correct session", "Wrong session read")
            try require(!TranscriptService.matches(url: URL(fileURLWithPath: "/tmp/session-a-other.jsonl"), sessionID: "session-a"), "Partial ID match")
            try require(TranscriptService.matches(url: URL(fileURLWithPath: "/tmp/manicode/projects/project/chats/chat/chat-messages.json"), sessionID: "manicode/project/chat"), "Codebuff identity missing")
            try require(!TranscriptService.matches(url: URL(fileURLWithPath: "/tmp/manicode/projects/other/chats/chat/chat-messages.json"), sessionID: "manicode/project/chat"), "Codebuff crossed project boundary")
        }
        await check("Chat: Gemini large JSON discovery and full content are preserved") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = root.appendingPathComponent(".gemini/tmp/project/chats")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let long = String(repeating: "Long message. ", count: 12_000) + "END-MARKER"
            let json: [String: Any] = ["sessionId":"session-a", "messages":[["type":"user","content":long]], "customMetadata":"kept"]
            try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("session-date-short.json"))
            let result = try await TranscriptService(home: root, environment: [:]).load(session: session("gemini"))
            try require(result.events.contains { $0.text == long }, "Long content truncated")
            try require(result.exportText.contains("END-MARKER") && result.exportText.contains("customMetadata"), "Export is incomplete")
            let custom = try await TranscriptService(home: root, environment: ["GEMINI_DATA_DIR": "  " + dir.path + "  "]).load(session: session("gemini"))
            try require(custom.messageCount == 1, "Gemini custom directory ignored")
        }
        await check("Chat: interrupted JSONL retains valid records and reports damage") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("chat.jsonl")
            try "{\"role\":\"user\",\"content\":\"hello\"}\n{incomplete".write(to: url, atomically: true, encoding: .utf8)
            let result = try await TranscriptService().load(session: session("claude"), file: url)
            try require(result.messageCount == 1 && result.events.count == 2, "Good record discarded")
            try require(result.notices.contains { $0.contains("разобрать") } && result.exportText.contains("{incomplete"), "Damage silently ignored")
        }
        await check("Chat: SQLite filters sessions, loads parts and leaves source unchanged") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("opencode.db")
            var db: OpaquePointer?
            sqlite3_open(url.path, &db)
            let sql = #"""
            CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT, session_id TEXT, message_id TEXT, data TEXT);
            INSERT INTO message VALUES ('m1','session-a',1,'{"role":"user"}'), ('m2','session-a',2,'{"role":"assistant"}'), ('m3','other',3,'{"role":"user","content":"must not leak"}');
            INSERT INTO part VALUES ('p1','session-a','m1','{"type":"text","text":"Question"}'), ('p2','session-a','m2','{"type":"text","text":"Answer"}');
            """#
            try require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Fixture DB failed")
            sqlite3_close(db)
            let before = try Data(contentsOf: url)
            let result = try await TranscriptService(home: root, environment: ["OPENCODE_DATA_DIR":root.path]).load(session: session("opencode"))
            try require(result.events.map(\.text) == ["Question", "Answer"], "SQLite parts/order/session scope broken")
            let after = try Data(contentsOf: url)
            try require(before == after, "Source DB was mutated")
            let wrong = try TranscriptDatabase.read(url, sessionID: "' OR 1=1 --")
            try require(wrong.isEmpty, "Session ID was not parameterized")
        }
        await check("Chat: OpenClaw SQLite and Hermes/Goose message columns") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for source in ["openclaw", "hermes", "goose"] {
                let url = root.appendingPathComponent(source + ".db")
                var db: OpaquePointer?
                sqlite3_open(url.path, &db)
                let sql = source == "openclaw" ? #"CREATE TABLE transcript_events (session_id TEXT,seq INTEGER,event_json TEXT); INSERT INTO transcript_events VALUES ('session-a',1,'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}');"# : #"CREATE TABLE messages (id INTEGER,session_id TEXT,role TEXT,content TEXT); INSERT INTO messages VALUES (1,'session-a','assistant','[{"type":"text","text":"hello"}]');"#
                try require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "DB setup")
                sqlite3_close(db)
                var decoder = TranscriptDecoder(source: source)
                for row in try TranscriptDatabase.read(url, sessionID: "session-a") { decoder.append(row) }
                try require(decoder.finish().first?.text == "hello", "SQLite content not decoded for \(source)")
            }
        }
        await check("Chat: missing and unsupported sources never fabricate a conversation") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let service = TranscriptService(home: root, environment: [:])
            for source in ["claude", "antigravity", "future-source"] {
                do { _ = try await service.load(session: session(source)); throw TranscriptCheckFailure(description: "Missing source reported success") }
                catch is TranscriptError { }
            }
        }
    }
}
