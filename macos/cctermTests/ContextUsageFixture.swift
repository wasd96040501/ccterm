import AgentSDK
import Foundation

/// A `get_context_usage` answer with every section present, as the CLI sends
/// it.
enum ContextUsageFixture {
    static let json = """
        {"categories":[
          {"name":"System prompt","tokens":3100,"color":"promptBorder"},
          {"name":"System tools","tokens":14200,"color":"inactive"},
          {"name":"MCP tools","tokens":1800,"color":"cyan_FOR_SUBAGENTS_ONLY"},
          {"name":"Custom agents","tokens":420,"color":"permission"},
          {"name":"Memory files","tokens":1750,"color":"claude"},
          {"name":"Skills","tokens":610,"color":"warning"},
          {"name":"Messages","tokens":31000,"color":"purple_FOR_SUBAGENTS_ONLY"},
          {"name":"Deferred tools","tokens":9000,"color":"inactive","isDeferred":true},
          {"name":"Free space","tokens":98120,"color":"promptBorder"}],
         "memoryFiles":[
          {"path":"/Users/me/dev/ccterm/CLAUDE.md","type":"Project","tokens":1200},
          {"path":"/Users/me/.claude/CLAUDE.md","type":"User","tokens":550}],
         "mcpTools":[
          {"name":"mcp__github__create_issue","serverName":"github","tokens":900,"isLoaded":true},
          {"name":"mcp__github__list_prs","serverName":"github","tokens":900,"isLoaded":false}],
         "deferredBuiltinTools":[],
         "agents":[{"agentType":"Explore","source":"Built-in","tokens":220},{"agentType":"reviewer","source":"Project","tokens":200}],
         "skills":{"totalSkills":14,"includedSkills":11,"tokens":610},
         "slashCommands":{"totalCommands":32,"includedCommands":28,"tokens":380},
         "totalTokens":61880,"maxTokens":160000,"rawMaxTokens":200000,"percentage":39,
         "model":"claude-opus-4-5","isAutoCompactEnabled":true,"autoCompactThreshold":150000}
        """

    static var sample: ContextUsage {
        try! JSONDecoder().decode(ContextUsage.self, from: Data(json.utf8))
    }
}
