import AppKit

/// The glyphs the transcript's design sheet draws (`design/transcript`, built by
/// `design/transcript-icons`), from the package's catalogue. All are template
/// images: tint them. `transcriptTile…` are a tile's glyphs on the 16-pt grid
/// (`GLYPHS`), `transcriptIcon…` a row's small marks (`ICON`), `transcriptLive…`
/// the live parts' marks (`LV`).
extension NSImage {
    public static var transcriptTileAdvisor: NSImage {
        Bundle.module.image(forResource: "TranscriptTileAdvisor") ?? NSImage()
    }
    public static var transcriptTileAgent: NSImage {
        Bundle.module.image(forResource: "TranscriptTileAgent") ?? NSImage()
    }
    public static var transcriptTileChange: NSImage {
        Bundle.module.image(forResource: "TranscriptTileChange") ?? NSImage()
    }
    public static var transcriptTileCommand: NSImage {
        Bundle.module.image(forResource: "TranscriptTileCommand") ?? NSImage()
    }
    public static var transcriptTileCreate: NSImage {
        Bundle.module.image(forResource: "TranscriptTileCreate") ?? NSImage()
    }
    public static var transcriptTileFail: NSImage {
        Bundle.module.image(forResource: "TranscriptTileFail") ?? NSImage()
    }
    public static var transcriptTileImage: NSImage {
        Bundle.module.image(forResource: "TranscriptTileImage") ?? NSImage()
    }
    public static var transcriptTileLocal: NSImage {
        Bundle.module.image(forResource: "TranscriptTileLocal") ?? NSImage()
    }
    public static var transcriptTileMessage: NSImage {
        Bundle.module.image(forResource: "TranscriptTileMessage") ?? NSImage()
    }
    public static var transcriptTileMonitor: NSImage {
        Bundle.module.image(forResource: "TranscriptTileMonitor") ?? NSImage()
    }
    public static var transcriptTileNotify: NSImage {
        Bundle.module.image(forResource: "TranscriptTileNotify") ?? NSImage()
    }
    public static var transcriptTileOther: NSImage {
        Bundle.module.image(forResource: "TranscriptTileOther") ?? NSImage()
    }
    public static var transcriptTilePlan: NSImage {
        Bundle.module.image(forResource: "TranscriptTilePlan") ?? NSImage()
    }
    public static var transcriptTileQuestion: NSImage {
        Bundle.module.image(forResource: "TranscriptTileQuestion") ?? NSImage()
    }
    public static var transcriptTileRead: NSImage {
        Bundle.module.image(forResource: "TranscriptTileRead") ?? NSImage()
    }
    public static var transcriptTileSchedule: NSImage {
        Bundle.module.image(forResource: "TranscriptTileSchedule") ?? NSImage()
    }
    public static var transcriptTileSearch: NSImage {
        Bundle.module.image(forResource: "TranscriptTileSearch") ?? NSImage()
    }
    public static var transcriptTileSession: NSImage {
        Bundle.module.image(forResource: "TranscriptTileSession") ?? NSImage()
    }
    public static var transcriptTileSkill: NSImage {
        Bundle.module.image(forResource: "TranscriptTileSkill") ?? NSImage()
    }
    public static var transcriptTileStop: NSImage {
        Bundle.module.image(forResource: "TranscriptTileStop") ?? NSImage()
    }
    public static var transcriptTileTasks: NSImage {
        Bundle.module.image(forResource: "TranscriptTileTasks") ?? NSImage()
    }
    public static var transcriptTileWeb: NSImage { Bundle.module.image(forResource: "TranscriptTileWeb") ?? NSImage() }
    public static var transcriptTileWorkflow: NSImage {
        Bundle.module.image(forResource: "TranscriptTileWorkflow") ?? NSImage()
    }
    public static var transcriptTileWorktree: NSImage {
        Bundle.module.image(forResource: "TranscriptTileWorktree") ?? NSImage()
    }

    public static var transcriptIconBack: NSImage {
        Bundle.module.image(forResource: "TranscriptIconBack") ?? NSImage()
    }
    public static var transcriptIconChevron: NSImage {
        Bundle.module.image(forResource: "TranscriptIconChevron") ?? NSImage()
    }
    public static var transcriptIconCopy: NSImage {
        Bundle.module.image(forResource: "TranscriptIconCopy") ?? NSImage()
    }
    public static var transcriptIconGo: NSImage { Bundle.module.image(forResource: "TranscriptIconGo") ?? NSImage() }
    public static var transcriptIconInfo: NSImage {
        Bundle.module.image(forResource: "TranscriptIconInfo") ?? NSImage()
    }
    public static var transcriptIconOctagon: NSImage {
        Bundle.module.image(forResource: "TranscriptIconOctagon") ?? NSImage()
    }
    public static var transcriptIconPin: NSImage { Bundle.module.image(forResource: "TranscriptIconPin") ?? NSImage() }
    public static var transcriptIconPinHollow: NSImage {
        Bundle.module.image(forResource: "TranscriptIconPinHollow") ?? NSImage()
    }
    public static var transcriptIconShield: NSImage {
        Bundle.module.image(forResource: "TranscriptIconShield") ?? NSImage()
    }
    public static var transcriptIconStopcircle: NSImage {
        Bundle.module.image(forResource: "TranscriptIconStopcircle") ?? NSImage()
    }
    public static var transcriptIconX: NSImage { Bundle.module.image(forResource: "TranscriptIconX") ?? NSImage() }

    public static var transcriptLiveBolt: NSImage {
        Bundle.module.image(forResource: "TranscriptLiveBolt") ?? NSImage()
    }
    public static var transcriptLiveCheck: NSImage {
        Bundle.module.image(forResource: "TranscriptLiveCheck") ?? NSImage()
    }
    public static var transcriptLiveChev: NSImage {
        Bundle.module.image(forResource: "TranscriptLiveChev") ?? NSImage()
    }
    public static var transcriptLiveChev2: NSImage {
        Bundle.module.image(forResource: "TranscriptLiveChev2") ?? NSImage()
    }
    public static var transcriptLiveClock: NSImage {
        Bundle.module.image(forResource: "TranscriptLiveClock") ?? NSImage()
    }
    public static var transcriptLiveFolder: NSImage {
        Bundle.module.image(forResource: "TranscriptLiveFolder") ?? NSImage()
    }
    public static var transcriptLivePlus: NSImage {
        Bundle.module.image(forResource: "TranscriptLivePlus") ?? NSImage()
    }
    public static var transcriptLiveStop: NSImage {
        Bundle.module.image(forResource: "TranscriptLiveStop") ?? NSImage()
    }
    public static var transcriptLiveSub: NSImage { Bundle.module.image(forResource: "TranscriptLiveSub") ?? NSImage() }
    public static var transcriptLiveUp: NSImage { Bundle.module.image(forResource: "TranscriptLiveUp") ?? NSImage() }
}
