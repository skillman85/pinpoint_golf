import Foundation
import WatchConnectivity

final class WatchRoundStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published var activeRound: WatchRoundPayload?
    @Published var isConnected = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func update(_ hole: WatchHolePayload, currentHoleIndex: Int) {
        guard var activeRound else { return }
        guard let holeIndex = activeRound.holes.firstIndex(where: { $0.number == hole.number }) else { return }
        activeRound.holes[holeIndex] = hole
        activeRound.currentHoleIndex = currentHoleIndex
        self.activeRound = activeRound
        send(update: WatchHoleUpdatePayload(currentHoleIndex: currentHoleIndex, hole: hole))
    }

    func move(to index: Int) {
        guard var activeRound else { return }
        activeRound.currentHoleIndex = min(max(0, index), max(0, activeRound.holes.count - 1))
        self.activeRound = activeRound
        if let hole = activeRound.holes[safe: activeRound.currentHoleIndex] {
            send(update: WatchHoleUpdatePayload(currentHoleIndex: activeRound.currentHoleIndex, hole: hole))
        }
    }

    private func send(update: WatchHoleUpdatePayload) {
        guard let session, let data = try? encoder.encode(update) else { return }
        let payload = ["holeUpdate": data]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil)
        } else {
            try? session.updateApplicationContext(payload)
        }
    }

    private func receive(_ payload: [String: Any]) {
        if payload["activeRoundCleared"] as? Bool == true {
            DispatchQueue.main.async {
                self.activeRound = nil
            }
            return
        }

        guard let data = payload["activeRound"] as? Data,
              let round = try? decoder.decode(WatchRoundPayload.self, from: data) else {
            return
        }
        DispatchQueue.main.async {
            self.activeRound = round
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = activationState == .activated
        }
    }

#if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isConnected = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
