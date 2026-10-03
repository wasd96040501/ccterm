import DisplayModels

/// The values the row views are held to, as the page builds them from the
/// CLI's messages — written out, since the package can't see a call.
enum RowModels {
    static func option(
        _ label: String, _ detail: String, chosen: Bool = false, preview: String? = nil
    )
        -> Question.Item.Option
    {
        Question.Item.Option(label: label, detail: detail, isChosen: chosen, preview: preview)
    }

    static func item(
        _ header: String, _ text: String, several: Bool = false, _ options: [Question.Item.Option]
    ) -> Question.Item {
        Question.Item(header: header, text: text, options: options, allowsSeveral: several)
    }

    static let notAnswered = "Not answered"
    static let talkedOver = "Not answered — talked over in the conversation"

    static func question(
        _ items: [Question.Item], waiting: Bool = false, outcome: String? = nil, talkedOver: Bool = false
    ) -> Question {
        Question(id: "q", items: items, isWaiting: waiting, outcome: outcome, isTalkedOver: talkedOver)
    }

    // MARK: - Questions

    static let dateLibrary = "Which library should we use for date formatting?"

    /// The sheet's one question; `chosen` is the label picked, a label of none is typed (*Other*).
    static func one(chosen: String? = nil, waiting: Bool = false) -> Question {
        var options = [
            option("date-fns", "Small, tree-shakeable", chosen: chosen == "date-fns"),
            option("Moment", "", chosen: chosen == "Moment"),
        ]
        if let chosen, !options.contains(where: \.isChosen) { options.append(option(chosen, "Other", chosen: true)) }
        return question([item("Auth method", dateLibrary, options)], waiting: waiting)
    }

    static func long(waiting: Bool = false) -> Question {
        question(
            [
                item(
                    "",
                    "Which of these approaches to reworking the tab bar do you want me to take, given that the split editor keeps its own tab strip and both must keep working when a document opens beside the transcript?",
                    [
                        option(
                            "A very long option label that will not fit a narrow split editor at all",
                            "and a description that is just as long as the label is, so both must truncate"),
                        option("Short", "x"),
                    ])
            ], waiting: waiting)
    }

    /// Two questions, the first of several.
    static func several(chosen: Set<String> = [], waiting: Bool = false) -> Question {
        question(
            [
                item(
                    "Targets", "Which platforms?", several: true,
                    [
                        option("macOS", "14+", chosen: chosen.contains("macOS")),
                        option("iOS", "", chosen: chosen.contains("iOS")),
                        option("visionOS", "Later", chosen: chosen.contains("visionOS")),
                    ]),
                item(
                    "Release", "Ship it?",
                    [
                        option("Yes", "", chosen: chosen.contains("Yes")),
                        option("No", "", chosen: chosen.contains("No")),
                    ]),
            ], waiting: waiting)
    }

    /// Two layouts, each with a preview: the *Notes* field.
    static func layout(
        previews: Bool, waiting: Bool = true, outcome: String? = nil, talkedOver: Bool = false
    )
        -> Question
    {
        question(
            [
                item(
                    "Layout", "Which layout?",
                    [
                        option("Split", "Two", preview: previews ? "+--+" : nil),
                        option("Tabs", "One", preview: previews ? "[a]" : nil),
                    ])
            ], waiting: waiting, outcome: outcome, talkedOver: talkedOver)
    }
}
