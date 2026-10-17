import GhosttyKit

// Placeholder until Task 5; forces linking of libghostty.
public enum GhosttyBridgeModule {
    public static var libraryVersion: String {
        let info = ghostty_info()
        return String(cString: info.version)
    }
}
