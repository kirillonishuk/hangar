import Exec
import Foundation
import Testing
@testable import HangarUI

/// «Удалённый проект»'s «Путь» suggestions (HD-164): what is listed for the typed text and which folders are offered.
@Suite struct RemotePathSuggestionTests {
    @Test func typedPathSplitsIntoFolderAndPrefix() {
        #expect(remotePathCompletion("~/src/ap") == ("~/src/", "ap"))
        #expect(remotePathCompletion("~/src/") == ("~/src/", ""))
        #expect(remotePathCompletion("~") == ("~/", ""))
        #expect(remotePathCompletion("") == ("", ""))
        #expect(remotePathCompletion("src") == ("", "src"))
        #expect(remotePathCompletion("/") == ("/", ""))
        #expect(remotePathCompletion(" /srv/a ") == ("/srv/", "a"))
    }

    @Test func listedFolderResolvesAgainstHome() {
        #expect(remoteFullPath("", home: "/home/u") == "/home/u/")
        #expect(remoteFullPath("~/", home: "/home/u") == "/home/u/")
        #expect(remoteFullPath("~/src/", home: "/home/u") == "/home/u/src/")
        #expect(remoteFullPath("/srv/", home: "/home/u") == "/srv/")
        #expect(remoteFullPath("src/", home: "/home/u") == "/home/u/src/")
    }

    @Test func onlyMatchingFoldersAreOffered() {
        let listing = parseRemoteListing(Data("dapi\0Dapp-link\0fapp.txt\0d.app-cache\0dBuild\0lapp-file-link\0".utf8))
        #expect(remoteFolderSuggestions(listing, dir: "~/src/", prefix: "ap") == ["~/src/api/", "~/src/app-link/"])
        #expect(remoteFolderSuggestions(listing, dir: "", prefix: "") == ["api/", "app-link/", "Build/"])
        #expect(remoteFolderSuggestions(listing, dir: "/", prefix: "B") == ["/Build/"])
        #expect(remoteFolderSuggestions(listing, dir: "/", prefix: ".") == ["/.app-cache/"])
    }

    /// The host's runner gets the listing script; its exit codes become the listing's errors.
    @Test func runnerListingParsesAndFails() async throws {
        let ok = Runner { args, _ in
            #expect(args.prefix(2) == ["sh", "-c"] && args.suffix(2) == ["/home/u/src/", "500"])
            return RunResult(status: 0, stdout: "dweb\0fREADME\0", stderr: "")
        }
        let listing = try await listRemoteFolder(ok, path: "/home/u/src/", limit: 500)
        #expect(listing.entries.map(\.name) == ["web", "README"])
        let missing = Runner { _, _ in RunResult(status: 3, stdout: "", stderr: "") }
        await #expect(throws: RemoteFileError.missing("/nope")) { try await listRemoteFolder(missing, path: "/nope") }
    }
}
