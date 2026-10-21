@testable import HangarUI
import Power

extension KeepAwake {
    /// Never touches IOKit and never arms a real timer: AppState tests must not hold the Mac awake.
    @MainActor static func inert() -> KeepAwake {
        KeepAwake(assertions: PowerAssertions(create: { _ in 1 }, rename: { _, _ in true }, release: { _ in }),
                  schedule: { _, _ in {} })
    }
}
