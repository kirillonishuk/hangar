import AppKit
import Integration
import SwiftUI

/// The integration questions (#111) as sheets on the main window, one at a time.
extension MainWindowController {
    func presentIntegrationAsk() {
        guard integrationSheet == nil, let window, let ask = app.integrations.ask else { return }
        let app = self.app
        let expose: (@escaping (Bool) -> Void, @escaping () -> Void) -> Void = { [weak self] answer, diff in
            self?.integrationSheetAnswer = answer
            self?.integrationSheetDiff = diff
        }
        var answered = false
        integrationSheet = window.beginHangarSheet({ end in
            switch ask {
            case .agent(let agent):
                AnyView(IntegrationAgentSheet(
                    agent: agent, whereItems: { app.askWhereItems() },
                    preview: { await app.previewAgent(agent, choice: $0) },
                    onAnswer: { connect, choice in
                        guard !answered else { return }
                        answered = true
                        end(.OK)
                        Task { await app.answerAgent(agent, connect: connect, choice: choice) }
                    },
                    expose: expose))
            case .host(let host):
                AnyView(IntegrationHostSheet(
                    host: host, parts: { app.hostParts() },
                    preview: { await app.previewHost(host) },
                    onAnswer: { connect in
                        guard !answered else { return }
                        answered = true
                        end(.OK)
                        Task { await app.answerHost(host, connect: connect) }
                    },
                    expose: expose))
            }
        }, done: { [weak self] _ in
            self?.integrationSheet = nil
            self?.integrationSheetAnswer = nil
            self?.integrationSheetDiff = nil
            // Ended from outside (a forced quit): the question stays for the next launch, the tabs keep waiting.
        })
    }
}
