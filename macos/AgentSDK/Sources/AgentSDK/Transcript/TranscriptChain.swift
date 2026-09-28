import Foundation

/// Rebuilds the current conversation branch from a transcript file, following
/// the CLI's own `--resume` loader:
///
/// 1. Index chain rows by uuid. A repeated uuid keeps its first position and
///    its last content. Legacy `progress` rows are dropped, and their children
///    re-parented to the nearest real ancestor.
/// 2. Relink each compaction's preserved rows behind its summary, so the
///    walk skips pre-compaction history.
/// 3. Pick the leaf: walk back from the most recently written terminal row
///    of the main chain to its nearest message, unless that does not descend
///    from the recorded `last-prompt` leaf (a rewind), which then wins.
/// 4. Walk `parentUuid` to the root. A missing parent falls back to the
///    closest earlier row within 5 s.
/// 5. Splice in the parts of each assistant response that are off the walked
///    path: sibling blocks of parallel tool calls and their results.
///
/// A subagent's own file (`<session>/subagents/agent-<id>.jsonl`) holds only
/// sidechain rows; there the sidechain is the conversation, so it is walked
/// the way a session's main chain is.
struct TranscriptChain {
    private(set) var metadata = SessionMetadata()
    private var rows: [String: Row] = [:]
    /// Order of first appearance.
    private var position: [String: Int] = [:]
    /// Line index of the latest write.
    private var lastWrite: [String: Int] = [:]
    private var progressParents: [String: String?] = [:]
    private var parentOverrides: [String: String] = [:]
    private var leafHint: String?
    private var clearedByRewind = false
    /// Which side of the sidechain split is the conversation: the main chain,
    /// or — in a subagent's own file — the sidechain.
    private var threadIsSidechain = false

    init(data: Data) {
        let decoder = JSONDecoder()
        var index = 0
        for (lineIndex, line) in Self.lines(of: data).enumerated() {
            guard let row = try? decoder.decode(Row.self, from: line) else { continue }
            if row.isChainRow {
                guard let uuid = row.uuid else { continue }
                if row.type == "progress" {
                    progressParents[uuid] = row.parentUUID
                    continue
                }
                var stored = row
                stored.line = line
                rows[uuid] = stored
                lastWrite[uuid] = lineIndex
                if position[uuid] == nil {
                    position[uuid] = index
                    index += 1
                }
                fold(row)
            } else {
                foldMetadata(row)
            }
        }
        threadIsSidechain = !rows.isEmpty && rows.values.allSatisfy(\.isSidechain)
        let boundaries = rows.values.filter { $0.type == "system" && $0.subtype == "compact_boundary" }
        for boundary in boundaries.sorted(by: { position[$0.uuid!]! < position[$1.uuid!]! }) {
            relink(boundary.preserved)
        }
    }

    // MARK: - Messages

    func messages() -> [Message] {
        guard !clearedByRewind, let leaf = chooseLeaf() else { return [] }
        return withParallelResults(walk(from: leaf)).compactMap(message)
    }

    private func message(_ uuid: String) -> Message? {
        guard let row = rows[uuid], let line = row.line, isOnThread(row) else { return nil }
        let decoder = JSONDecoder()
        switch row.type {
        case "user":
            return (try? decoder.decode(UserMessage.self, from: line)).map(Message.user)
        case "assistant":
            return (try? decoder.decode(AssistantMessage.self, from: line)).map(Message.assistant)
        case "system" where row.subtype == "compact_boundary":
            return .system(.compactBoundary(row.compactBoundary ?? .init(trigger: "", preTokens: 0, postTokens: nil)))
        case "attachment":
            guard let prompt = row.queuedPrompt else { return nil }
            return .user(
                UserMessage(
                    uuid: uuid, sessionID: row.sessionID, content: prompt, isSynthetic: row.isMeta,
                    origin: row.queuedOrigin, timestamp: row.timestamp))
        default:
            return nil
        }
    }

    // MARK: - Chain

    private func isOnThread(_ row: Row) -> Bool {
        row.isSidechain == threadIsSidechain && !row.isTeam
    }

    private func parent(of uuid: String) -> String? {
        var next = parentOverrides[uuid] ?? rows[uuid]?.parentUUID
        var hops = 0
        while let candidate = next, let collapsed = progressParents[candidate], hops < 10_000 {
            next = collapsed
            hops += 1
        }
        return next
    }

    /// Re-chains a compaction's preserved rows behind its summary
    /// (`anchor → first … last`) and moves the anchor's other children to the
    /// last preserved row. Full compactions (nothing preserved) need nothing:
    /// the boundary has no parent, so the walk stops there.
    private mutating func relink(_ preserved: Row.Preserved?) {
        let anchor: String
        let first: String
        let last: String
        switch preserved {
        case .messages(let messagesAnchor, let uuids):
            guard let head = uuids.first, let tail = uuids.last, uuids.allSatisfy({ rows[$0] != nil }) else { return }
            var previous = messagesAnchor
            for uuid in uuids {
                parentOverrides[uuid] = previous
                previous = uuid
            }
            (anchor, first, last) = (messagesAnchor, head, tail)
        case .segment(let head, let segmentAnchor, let tail):
            if rows[head] != nil { parentOverrides[head] = segmentAnchor }
            (anchor, first, last) = (segmentAnchor, head, tail)
        case nil:
            return
        }
        for uuid in rows.keys where uuid != first && parent(of: uuid) == anchor {
            parentOverrides[uuid] = last
        }
    }

    private func chooseLeaf() -> String? {
        let mainChain = rows.values.filter(isOnThread)
        var hasChild = Set<String>()
        for row in mainChain {
            if let uuid = row.uuid, let parent = parent(of: uuid) { hasChild.insert(parent) }
        }
        let terminals = mainChain.compactMap(\.uuid).filter { !hasChild.contains($0) }
            .sorted { lastWrite[$0, default: -1] > lastWrite[$1, default: -1] }
        var leaf: String?
        var checked = Set<String>()
        search: for terminal in terminals {
            var trail: [String] = []
            var cursor: String? = terminal
            while let uuid = cursor, let row = rows[uuid], !checked.contains(uuid), !trail.contains(uuid) {
                if row.type == "user" || row.type == "assistant" {
                    leaf = uuid
                    break search
                }
                trail.append(uuid)
                cursor = parent(of: uuid)
            }
            checked.formUnion(trail)
        }
        guard let hint = leafHint, rows[hint] != nil else { return leaf }
        guard let leaf else { return hint }
        return descends(leaf, from: hint) ? leaf : hint
    }

    private func descends(_ uuid: String, from ancestor: String) -> Bool {
        var cursor: String? = uuid
        var seen = Set<String>()
        while let current = cursor, seen.insert(current).inserted {
            if current == ancestor { return true }
            cursor = parent(of: current)
        }
        return false
    }

    /// Leaf-to-root walk, returned root first.
    private func walk(from leaf: String) -> [String] {
        var path: [String] = []
        var visited = Set<String>()
        var cursor: String? = leaf
        while let uuid = cursor, let row = rows[uuid], visited.insert(uuid).inserted {
            path.append(uuid)
            guard let parent = parent(of: uuid) else { break }
            cursor = rows[parent] != nil ? parent : nearestEarlier(than: row, excluding: visited)
        }
        return path.reversed()
    }

    /// The latest unvisited row on the same side of the sidechain split that
    /// is at most 5 s older than `row`.
    private func nearestEarlier(than row: Row, excluding visited: Set<String>) -> String? {
        guard let time = row.timestamp else { return nil }
        return rows.values
            .filter { candidate in
                guard let t = candidate.timestamp, let uuid = candidate.uuid else { return false }
                return candidate.isSidechain == row.isSidechain && !visited.contains(uuid) && t <= time
                    && time.timeIntervalSince(t) <= 5
            }
            .max { $0.timestamp! < $1.timestamp! }?.uuid
    }

    /// Adds the parts of each assistant response that the walk missed. The
    /// CLI writes a response as one row per block and chains tool results to
    /// the block that called the tool, so parallel calls leave sibling blocks
    /// and their results on side branches. They are inserted, oldest first,
    /// after the response's last block on the path.
    private func withParallelResults(_ path: [String]) -> [String] {
        let assistantsOnPath = path.filter { rows[$0]?.messageID != nil }
        guard !assistantsOnPath.isEmpty else { return path }

        var included = Set(path)
        var blocks: [String: [String]] = [:]
        // The block that issued each tool call; `nil` when two responses claim it.
        var caller: [String: String?] = [:]
        var resultRows: [String] = []
        for uuid in rows.keys.sorted(by: { position[$0]! < position[$1]! }) {
            guard let row = rows[uuid] else { continue }
            if let messageID = row.messageID {
                blocks[messageID, default: []].append(uuid)
                for id in row.toolUseIDs {
                    if let previous = caller[id] {
                        caller[id] = previous.flatMap { rows[$0]?.messageID } == messageID ? uuid : nil
                    } else {
                        caller[id] = uuid
                    }
                }
            } else if !row.toolResultIDs.isEmpty, row.parentUUID != nil {
                resultRows.append(uuid)
            }
        }

        // Result rows reachable from each block: by parent, by source
        // assistant, or by the tool call they answer.
        var attached: [String: [String]] = [:]
        var attachedPairs = Set<[String]>()
        func attach(_ result: String, to block: String) {
            if attachedPairs.insert([block, result]).inserted { attached[block, default: []].append(result) }
        }
        for uuid in resultRows {
            guard let row = rows[uuid], let parent = row.parentUUID else { continue }
            attach(uuid, to: parent)
            if let source = row.sourceToolAssistantUUID, source != parent, let other = rows[source],
                row.sameThread(as: other)
            {
                attach(uuid, to: source)
            }
            for id in row.toolResultIDs {
                if let block = caller[id] ?? nil, let other = rows[block], row.sameThread(as: other) {
                    attach(uuid, to: block)
                }
            }
        }

        let answeredOnPath = Set(path.flatMap { rows[$0]?.toolResultIDs ?? [] })
        var lastOnPath: [String: String] = [:]
        for uuid in assistantsOnPath { lastOnPath[rows[uuid]!.messageID!] = uuid }

        var insertions: [String: [String]] = [:]
        var handled = Set<String>()
        for uuid in assistantsOnPath {
            guard let messageID = rows[uuid]?.messageID, handled.insert(messageID).inserted else { continue }
            let group = blocks[messageID] ?? [uuid]
            let groupSet = Set(group)
            let offPath = group.filter { !included.contains($0) }
            var direct: [String] = []
            var indirect: [String] = []
            var seen = Set<String>()
            for block in group {
                for result in attached[block] ?? [] where !included.contains(result) && seen.insert(result).inserted {
                    if let parent = rows[result]?.parentUUID, groupSet.contains(parent) {
                        direct.append(result)
                    } else {
                        indirect.append(result)
                    }
                }
            }
            if !indirect.isEmpty {
                var answered = answeredOnPath.union(direct.flatMap { rows[$0]?.toolResultIDs ?? [] })
                for result in indirect.sorted(by: { position[$0]! < position[$1]! }) {
                    let ids = rows[result]?.toolResultIDs ?? []
                    let answersGroup = ids.contains { id in
                        !answered.contains(id) && (caller[id] ?? nil).map(groupSet.contains) == true
                    }
                    guard answersGroup else { continue }
                    answered.formUnion(ids)
                    direct.append(result)
                }
            }
            guard !offPath.isEmpty || !direct.isEmpty else { continue }
            let spliced = byTimestamp(offPath) + byTimestamp(direct)
            included.formUnion(spliced)
            insertions[lastOnPath[messageID]!] = spliced
        }

        return path.flatMap { [$0] + (insertions[$0] ?? []) }
    }

    /// Stable sort by timestamp; rows without one first.
    private func byTimestamp(_ uuids: [String]) -> [String] {
        uuids.enumerated().sorted { a, b in
            let ta = rows[a.element]?.timestamp ?? .distantPast
            let tb = rows[b.element]?.timestamp ?? .distantPast
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Metadata

    private mutating func fold(_ row: Row) {
        if metadata.cwd == nil { metadata.cwd = row.cwd }
        if let branch = row.gitBranch { metadata.gitBranch = branch }
        if let time = row.timestamp {
            if metadata.createdAt.map({ time < $0 }) ?? true { metadata.createdAt = time }
            if metadata.updatedAt.map({ time > $0 }) ?? true { metadata.updatedAt = time }
        }
    }

    private mutating func foldMetadata(_ row: Row) {
        switch row.type {
        case "custom-title": metadata.customTitle = row.customTitle.flatMap { $0.isEmpty ? nil : $0 }
        case "ai-title": metadata.aiTitle = row.aiTitle
        case "tag": metadata.tag = row.tag.flatMap { $0.isEmpty ? nil : $0 }
        case "relocated": if let cwd = row.relocatedCwd { metadata.cwd = cwd }
        case "last-prompt":
            if let prompt = row.lastPrompt { metadata.lastPrompt = prompt }
            leafHint = row.leafUUID
            clearedByRewind = row.leafUUID == nil && row.explicit
        default: break
        }
    }

    // MARK: - Lines

    /// Non-empty lines, tolerating the NUL padding a torn write leaves.
    private static func lines(of data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            let trimmed = line.drop { $0 == 0 }
            return trimmed.isEmpty ? nil : Data(trimmed)
        }
    }
}

// MARK: - Row

/// The fields of one transcript line the chain needs; message bodies stay
/// undecoded until the line is known to be on the branch.
private struct Row: Decodable {
    enum Preserved {
        case segment(head: String, anchor: String, tail: String)
        case messages(anchor: String, uuids: [String])

        var anchor: String {
            switch self {
            case .segment(_, let anchor, _), .messages(let anchor, _): return anchor
            }
        }
    }

    let type: String
    let uuid: String?
    let parentUUID: String?
    let sessionID: String?
    let isSidechain: Bool
    let agentID: String?
    let isTeam: Bool
    let isMeta: Bool
    let timestamp: Date?
    let subtype: String?
    let messageID: String?
    let toolUseIDs: [String]
    let toolResultIDs: [String]
    let sourceToolAssistantUUID: String?
    let preserved: Preserved?
    let compactBoundary: SystemMessage.CompactBoundary?
    let queuedPrompt: [ContentBlock]?
    let queuedOrigin: String?
    let cwd: String?
    let gitBranch: String?
    // Metadata rows.
    let customTitle: String?
    let aiTitle: String?
    let tag: String?
    let lastPrompt: String?
    let leafUUID: String?
    let explicit: Bool
    let relocatedCwd: String?
    /// The raw line, kept for chain rows.
    var line: Data?

    /// Both rows are on the main thread, or in the same subagent.
    func sameThread(as other: Row) -> Bool {
        isSidechain == other.isSidechain && agentID == other.agentID
    }

    var isChainRow: Bool { ["user", "assistant", "attachment", "system", "progress"].contains(type) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        type = try c.required(String.self, "type")
        uuid = c.lenient(String.self, "uuid")
        parentUUID = c.lenient(String.self, "parentUuid")
        sessionID = c.lenient(String.self, "sessionId")
        isSidechain = c.lenientBool("isSidechain") ?? false
        agentID = c.lenient(String.self, "agentId")
        sourceToolAssistantUUID = c.lenient(String.self, "sourceToolAssistantUUID")
        isTeam = c.lenient(String.self, "teamName") != nil
        isMeta = c.lenientBool("isMeta") ?? false
        timestamp = c.timestamp("timestamp")
        subtype = c.lenient(String.self, "subtype")
        cwd = c.lenient(String.self, "cwd")
        gitBranch = c.lenient(String.self, "gitBranch")

        let message = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "message")
        let blocks = message?.lenientArray(BlockIDs.self, "content") ?? []
        messageID = type == "assistant" ? message?.lenient(String.self, "id") : nil
        toolUseIDs = blocks.filter { $0.type == "tool_use" }.compactMap(\.id)
        toolResultIDs = type == "user" ? blocks.filter { $0.type == "tool_result" }.compactMap(\.toolUseID) : []

        let compact = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "compactMetadata")
        if let compact {
            compactBoundary = SystemMessage.CompactBoundary(
                trigger: compact.lenient(String.self, "trigger") ?? "",
                preTokens: compact.lenientInt("preTokens") ?? 0,
                postTokens: compact.lenientInt("postTokens"))
            if let kept = try? compact.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "preservedMessages"),
                let anchor = kept.lenient(String.self, "anchorUuid"),
                let uuids = kept.lenient([String].self, "uuids"), !uuids.isEmpty
            {
                preserved = .messages(anchor: anchor, uuids: uuids)
            } else if let segment = try? compact.nestedContainer(
                keyedBy: AnyCodingKey.self, forKey: "preservedSegment"),
                let head = segment.lenient(String.self, "headUuid"),
                let anchor = segment.lenient(String.self, "anchorUuid"),
                let tail = segment.lenient(String.self, "tailUuid")
            {
                preserved = .segment(head: head, anchor: anchor, tail: tail)
            } else {
                preserved = nil
            }
        } else {
            compactBoundary = nil
            preserved = nil
        }

        let attachment = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "attachment")
        if type == "attachment", attachment?.lenient(String.self, "type") == "queued_command" {
            let mode = attachment?.lenient(String.self, "commandMode") ?? "prompt"
            queuedPrompt = mode == "prompt" || mode == "task-notification" ? attachment?.contentBlocks("prompt") : nil
            queuedOrigin = mode == "task-notification" ? "task-notification" : nil
        } else {
            queuedPrompt = nil
            queuedOrigin = nil
        }

        customTitle = c.lenient(String.self, "customTitle")
        aiTitle = c.lenient(String.self, "aiTitle")
        tag = c.lenient(String.self, "tag")
        lastPrompt = c.lenient(String.self, "lastPrompt")
        leafUUID = c.lenient(String.self, "leafUuid")
        explicit = c.lenientBool("explicit") ?? false
        relocatedCwd = c.lenient(String.self, "relocatedCwd")
    }
}

private struct BlockIDs: Decodable {
    let type: String?
    let id: String?
    let toolUseID: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        type = c.lenient(String.self, "type")
        id = c.lenient(String.self, "id")
        toolUseID = c.lenient(String.self, "tool_use_id")
    }
}
