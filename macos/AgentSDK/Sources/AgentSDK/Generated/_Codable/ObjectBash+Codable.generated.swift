import Foundation

extension ObjectBash {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectBash")
        self._raw = r.dict
        self.assistantAutoBackgrounded = r.bool("assistant_auto_backgrounded", alt: "assistantAutoBackgrounded")
        self.backgroundTaskId = r.string("background_task_id", alt: "backgroundTaskId")
        self.backgroundedByUser = r.bool("backgrounded_by_user", alt: "backgroundedByUser")
        self.interrupted = r.bool("interrupted")
        self.isImage = r.bool("is_image", alt: "isImage")
        self.noOutputExpected = r.bool("no_output_expected", alt: "noOutputExpected")
        self.persistedOutputPath = r.string("persisted_output_path", alt: "persistedOutputPath")
        self.persistedOutputSize = r.int("persisted_output_size", alt: "persistedOutputSize")
        self.returnCodeInterpretation = r.string("return_code_interpretation", alt: "returnCodeInterpretation")
        self.stderr = r.string("stderr")
        self.stdout = r.string("stdout")
        self.tokenSaverOutput = r.string("token_saver_output", alt: "tokenSaverOutput")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectBash {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = assistantAutoBackgrounded { d["assistant_auto_backgrounded"] = v }
        if let v = backgroundTaskId { d["background_task_id"] = v }
        if let v = backgroundedByUser { d["backgrounded_by_user"] = v }
        if let v = interrupted { d["interrupted"] = v }
        if let v = isImage { d["is_image"] = v }
        if let v = noOutputExpected { d["no_output_expected"] = v }
        if let v = persistedOutputPath { d["persisted_output_path"] = v }
        if let v = persistedOutputSize { d["persisted_output_size"] = v }
        if let v = returnCodeInterpretation { d["return_code_interpretation"] = v }
        if let v = stderr { d["stderr"] = v }
        if let v = stdout { d["stdout"] = v }
        if let v = tokenSaverOutput { d["token_saver_output"] = v }
        return d
    }
}
