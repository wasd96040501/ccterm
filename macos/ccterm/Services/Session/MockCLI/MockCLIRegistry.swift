#if DEBUG

import Foundation

/// 名字 → scenario factory 的查找表。UI test 通过环境变量
/// `CCTERM_MOCK_CLI_SCENARIO=<name>` 选用 scenario。
///
/// 新增 scenario 时在 `scenarios` 字典里加一行,**这是测试可见 scenario 的唯一入口**——
/// 不在这里注册的 scenario 不会被使用。
enum MockCLIRegistry {

    /// scenario 名字 → 无参 factory。名字必须与 UI test 里的环境变量值匹配。
    static let scenarios: [String: () -> any MockCLIScenario] = [
        "hangingTurn": { HangingTurnScenario() },
    ]

    /// 找不到名字时返回 nil;`MockCLIRunner` 会写 stderr 并以非零退出,
    /// `SessionHandle2` 的 launch failure 路径会 surface 给 UI/test。
    static func scenario(named name: String) -> (any MockCLIScenario)? {
        scenarios[name]?()
    }
}

#endif
