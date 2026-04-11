enum LanguageDetection {

    /// Map file path to highlight.js language name.
    /// Ported from web/src/components/DiffView/DiffView.tsx EXT_TO_LANG.
    static func language(for filePath: String) -> String? {
        let name = filePath.split(separator: "/").last.map(String.init)?.lowercased() ?? ""

        // Special filenames
        if name == "makefile" { return "makefile" }
        if name == "dockerfile" { return "dockerfile" }

        guard let ext = name.split(separator: ".").last.map(String.init) else { return nil }
        return extToLang[ext]
    }

    private static let extToLang: [String: String] = [
        "ts": "typescript", "tsx": "typescript",
        "js": "javascript", "jsx": "javascript",
        "py": "python", "rb": "ruby",
        "swift": "swift", "rs": "rust",
        "go": "go", "java": "java",
        "kt": "kotlin", "scala": "scala",
        "css": "css", "scss": "scss", "less": "less",
        "html": "xml", "xml": "xml", "svg": "xml",
        "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "ini",
        "md": "markdown", "sh": "bash", "zsh": "bash", "bash": "bash",
        "c": "c", "cpp": "cpp", "h": "c", "hpp": "cpp", "m": "objectivec",
        "sql": "sql", "graphql": "graphql",
        "php": "php", "pl": "perl",
        "r": "r", "lua": "lua",
    ]
}
