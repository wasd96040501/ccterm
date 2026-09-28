import Foundation

/// Rebuilds the current conversation branch from a transcript file, following
/// the CLI's own `--resume` loader:
///
/// 1. Index chain rows by uuid. A repeated uuid keeps its first position and
///    its last content. Legacy `progress` rows are dropped, and their children
///    re-parented to the nearest real ancestor.
/// 2. Relink the preserved segment of the last compaction behind its summary,
///    so the walk skips pre-compaction history.
/// 3. Pick the leaf: the newest main-chain message, unless it does not
///    descend from the recorded `last-prompt` leaf (a rewind), which wins.
/// 4. Walk `parentUuid` to the root. A missing parent falls back to the
///    closest earlier row within 5 s.
/// 5. Splice in parallel tool results that hang off sibling blocks of an
///    assistant response rather than off the walked path.
struct TranscriptChain {
    private(set) var metadata = SessionMetadata()
    private var rows: [String: Row] = [:]
    private var position: [String: Int] = [:]
    private var progressParents: [String: String?] = [:]
    private var parentOverrides: [String: String] = [:]
    private var leafHint: String?
    private var clearedByRewind = false

    init(data: Data) {
        let decoder = JSONDecoder()
        var lastBoundary: Row?
        var index = 0
        for line in Self.lines(of: data) {
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
                if position[uuid] == nil {
                    position[uuid] = index
                    index += 1
                }
                if row.type == "system", row.subtype == "compact_boundary" { lastBoundary = row }
                fold(row)
            } else {
                foldMetadata(row)
            }
        }
        if let lastBoundary { relink(after: lastBoundary) }
    }

    // MARK: - Messages

    func messages() -> [Message] {
        guard !clearedByRewind, let leaf = chooseLeaf() else { return [] }
        return withParallelResults(walk(from: leaf)).compactMap(message)
    }

    private func message(_ uuid: String) -> Message? {
        guard let row = rows[uuid], let line = row.line, !row.isSidechain, !row.isTeam else { return nil }
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

    private func parent(of uuid: String) -> String? {
        var next = parentOverrides[uuid] ?? rows[uuid]?.parentUUID
        var hops = 0
        while let candidate = next, let collapsed = progressParents[candidate], hops < 10_000 {
            next = collapsed
            hops += 1
        }
        return next
    }

    /// Re-chains the last compaction's preserved rows behind its summary
    /// (`anchor → head … tail`) and moves the anchor's other children to the
    /// tail. Full compactions (no preserved rows) need nothing: the boundary
    /// has no parent, so the walk stops there.
    private mutating func relink(after boundary: Row) {
        guard let preserved = boundary.preserved else { return }
        var segment: [String] = []
        switch preserved {
        case .messages(_, let uuids):
            segment = uuids.filter { rows[$0] != nil }
        case .segment(let head, _, let tail):
            var cursor: String? = tail
            var seen = Set<String>()
            while let uuid = cursor, rows[uuid] != nil, seen.insert(uuid).inserted {
                segment.append(uuid)
                if uuid == head { break }
                cursor = parent(of: uuid)
            }
            guard segment.last == head else { return }
            segment.reverse()
        }
        guard let first = segment.first, let tail = segment.last else { return }
        let anchor = preserved.anchor
        parentOverrides[first] = anchor
        for (earlier, later) in zip(segment, segment.dropFirst()) { parentOverrides[later] = earlier }
        let preservedSet = Set(segment)
        for (uuid, row) in rows where row.parentUUID == anchor && !preservedSet.contains(uuid) {
            parentOverrides[uuid] = tail
        }
    }

    private func chooseLeaf() -> String? {
        let newest = rows.values
            .filter { ($0.type == "user" || $0.type == "assistant") && !$0.isSidechain && !$0.isTeam }
            .max { position[$0.uuid!]! < position[$1.uuid!]! }?.uuid
        guard let hint = leafHint, rows[hint] != nil else { return newest }
        guard let newest else { return hint }
        return descends(newest, from: hint) ? newest : hint
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

    /// Inserts tool results whose `tool_use` belongs to a response on the
    /// path but which are not on the path themselves, right after that
    /// response's last block.
    private func withParallelResults(_ path: [String]) -> [String] {
        var answered = Set(path.flatMap { rows[$0]?.toolResultIDs ?? [] })
        var resultRows: [String: String] = [:]
        var blocksByMessage: [String: [String]] = [:]
        for (uuid, row) in rows where !row.isSidechain {
            for id in row.toolResultIDs where resultRows[id].map({ position[$0]! > position[uuid]! }) ?? true {
                resultRows[id] = uuid
            }
            if let messageID = row.messageID { blocksByMessage[messageID, default: []].append(uuid) }
        }
        let onPath = Set(path)
        var output: [String] = []
        for (i, uuid) in path.enumerated() {
            output.append(uuid)
            guard let messageID = rows[uuid]?.messageID,
                i + 1 == path.count || rows[path[i + 1]]?.messageID != messageID
            else { continue }
            let toolUseIDs = (blocksByMessage[messageID] ?? [])
                .sorted { position[$0]! < position[$1]! }
                .flatMap { rows[$0]?.toolUseIDs ?? [] }
            var recovered: [String] = []
            for id in toolUseIDs where !answered.contains(id) {
                guard let result = resultRows[id], !onPath.contains(result), !recovered.contains(result) else {
                    continue
                }
                recovered.append(result)
                answered.formUnion(rows[result]?.toolResultIDs ?? [])
            }
            output += recovered.sorted { position[$0]! < position[$1]! }
        }
        return output
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
    let isTeam: Bool
    let isMeta: Bool
    let timestamp: Date?
    let subtype: String?
    let messageID: String?
    let toolUseIDs: [String]
    let toolResultIDs: [String]
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

    var isChainRow: Bool { ["user", "assistant", "attachment", "system", "progress"].contains(type) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        type = try c.required(String.self, "type")
        uuid = c.lenient(String.self, "uuid")
        parentUUID = c.lenient(String.self, "parentUuid")
        sessionID = c.lenient(String.self, "sessionId")
        isSidechain = c.lenientBool("isSidechain") ?? false
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
            if let segment = try? compact.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "preservedSegment"),
                let head = segment.lenient(String.self, "headUuid"),
                let anchor = segment.lenient(String.self, "anchorUuid"),
                let tail = segment.lenient(String.self, "tailUuid")
            {
                preserved = .segment(head: head, anchor: anchor, tail: tail)
            } else if let kept = try? compact.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "preservedMessages"),
                let anchor = kept.lenient(String.self, "anchorUuid"),
                let uuids = kept.lenient([String].self, "uuids")
            {
                preserved = .messages(anchor: anchor, uuids: uuids)
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
