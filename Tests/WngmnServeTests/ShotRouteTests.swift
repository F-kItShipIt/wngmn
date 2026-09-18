import Foundation
import Network
import Synchronization
import Testing
import WngmnCore
@testable import WngmnServe

/// `POST /shot`: a key on this Mac asking the running wngmn to take a picture of the screen.
///
/// The route is the one thing on this server that makes the machine *do* something to itself
/// beyond transcribing, so it is held to more than the token: it is answered only to this
/// machine, whatever the listener is bound to.
@Suite("Shot route", .serialized)
struct ShotRouteTests {
    /// Records the modes the handler was given.
    final class Seen: Sendable {
        private let modes = Mutex<[ShotMode]>([])
        func record(_ mode: ShotMode) { modes.withLock { $0.append(mode) } }
        var all: [ShotMode] { modes.withLock { $0 } }
    }

    func withServer(
        port: UInt16, listenOnLAN: Bool = false, token: String? = nil, handled: Bool = true,
        _ body: (String, Seen) async throws -> Void
    ) async throws {
        let seen = Seen()
        var configuration = TranscriptServer.Configuration(port: port, listenOnLAN: listenOnLAN, token: token)
        if handled { configuration.onShot = { seen.record($0) } }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }
        try await body("127.0.0.1:\(port)", seen)
    }

    func post(_ url: String, _ body: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// The handler runs before the 202 is sent, as `/summarise` does and `/ask` does not — so
    /// what it recorded can be read the moment the status is back, with nothing to race.
    @Test("A shot from this Mac reaches the handler with its mode, and is accepted")
    func acceptsFromLoopback() async throws {
        try await withServer(port: 17403) { host, seen in
            let status1 = try await post("http://\(host)/shot", #"{"mode":"region"}"#).status
            #expect(status1 == 202)
            let status2 = try await post("http://\(host)/shot", #"{"mode":"screen"}"#).status
            #expect(status2 == 202)
            #expect(seen.all == [.region, .screen])
        }
    }

    @Test("A mode it does not know is refused, and nothing is taken")
    func refusesAnUnknownMode() async throws {
        try await withServer(port: 17404) { host, seen in
            let status3 = try await post("http://\(host)/shot", #"{"mode":"window"}"#).status
            #expect(status3 == 400)
            let status4 = try await post("http://\(host)/shot", "{}").status
            #expect(status4 == 400)
            let status5 = try await post("http://\(host)/shot", "not json").status
            #expect(status5 == 400)
            #expect(seen.all.isEmpty)
        }
    }

    @Test("With nothing to take the picture, it says so rather than accepting")
    func unconfiguredIsUnavailable() async throws {
        try await withServer(port: 17405, handled: false) { host, _ in
            let status6 = try await post("http://\(host)/shot", #"{"mode":"screen"}"#).status
            #expect(status6 == 503)
        }
    }

    @Test("It is POST only, and the token gates it like everything else")
    func methodAndToken() async throws {
        try await withServer(port: 17406, token: "abcd2345") { host, seen in
            var get = URLRequest(url: URL(string: "http://\(host)/shot?t=abcd2345")!)
            get.timeoutInterval = 5
            let (_, response) = try await URLSession.shared.data(for: get)
            #expect((response as? HTTPURLResponse)?.statusCode == 405)

            let status7 = try await post("http://\(host)/shot", #"{"mode":"screen"}"#).status
            #expect(status7 == 403)
            let status8 = try await post("http://\(host)/shot?t=abcd2345", #"{"mode":"screen"}"#).status
            #expect(status8 == 202)
            #expect(seen.all == [.screen])
        }
    }

    /// Anyone on the network who holds the token can already read the transcript. That must not
    /// extend to making this Mac photograph its own screen. The only way a test can arrive
    /// from somewhere other than loopback is to connect to this machine's own LAN address.
    @Test("From the network it is refused, even with the token and --listen",
          .enabled(if: TranscriptServer.primaryIPv4() != nil))
    func refusesFromTheNetwork() async throws {
        let lan = try #require(TranscriptServer.primaryIPv4())
        try await withServer(port: 17407, listenOnLAN: true, token: "abcd2345") { _, seen in
            let result = try await post("http://\(lan):17407/shot?t=abcd2345", #"{"mode":"screen"}"#)
            #expect(result.status == 403)
            #expect(seen.all.isEmpty, "a request from the network took a screenshot")
            // The same server still answers this machine.
            let status9 = try await post("http://127.0.0.1:17407/shot?t=abcd2345", #"{"mode":"screen"}"#).status
            #expect(status9 == 202)
        }
    }

    // MARK: - What counts as this machine

    func endpoint(_ host: NWEndpoint.Host) -> NWEndpoint { .hostPort(host: host, port: 50_000) }

    @Test("Loopback is 127.0.0.1 and ::1")
    func loopbackAddresses() {
        #expect(TranscriptServer.isLoopback(endpoint(.ipv4(.loopback))))
        #expect(TranscriptServer.isLoopback(endpoint(.ipv6(.loopback))))
    }

    /// `NWEndpoint.Host("::ffff:127.0.0.1")` normalises to IPv4, so the mapped form has to be
    /// built from its bytes to be tested at all. A dual-stack listener can hand one over, and
    /// its own `isLoopback` is false.
    @Test("An IPv4-mapped loopback address is still this machine")
    func mappedLoopback() throws {
        let bytes = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 0, 0, 1])
        let mapped = try #require(IPv6Address(bytes))
        #expect(!mapped.isLoopback, "the premise: Network.framework does not call this loopback")
        #expect(TranscriptServer.isLoopback(endpoint(.ipv6(mapped))))
    }

    @Test("Anything else is not: a LAN address, a name, a socket path")
    func everythingElseIsNot() throws {
        let lan = try #require(IPv4Address("10.0.0.146"))
        let otherLoopback = try #require(IPv4Address("127.0.0.2"))
        let linkLocal = try #require(IPv6Address("fe80::1"))
        #expect(!TranscriptServer.isLoopback(endpoint(.ipv4(lan))))
        #expect(!TranscriptServer.isLoopback(endpoint(.ipv4(otherLoopback))),
                "strict on purpose: the client only ever uses 127.0.0.1")
        #expect(!TranscriptServer.isLoopback(endpoint(.ipv6(linkLocal))))
        #expect(!TranscriptServer.isLoopback(endpoint(.name("localhost", nil))),
                "a name never arrives on an inbound connection, so it proves nothing")
        #expect(!TranscriptServer.isLoopback(.unix(path: "/tmp/x.sock")))
    }
}
