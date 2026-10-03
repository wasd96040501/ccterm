import Foundation

/// One model a `PageRowView` must draw within the height it declares for
/// it, and models that must lay out exactly as it does — the same row
/// selected, flashing, hovered: state that is paint, not geometry.
struct RowFixture<Model> {
    let name: String
    let model: Model
    var sameGeometry: [Model] = []
}
