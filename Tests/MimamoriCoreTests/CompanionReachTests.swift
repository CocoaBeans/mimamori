import Foundation
import Testing
@testable import MimamoriShared

/// Reaching the Mac away from its network, over Tailscale.
@Suite("Companion reach")
struct CompanionReachTests {
    @Test func picksTheTailnetAddresses() {
        let interfaces: [(name: String, address: String)] = [
            ("lo0", "127.0.0.1"),
            ("en0", "192.168.1.20"),
            ("en0", "fe80::1c2b:3a"),
            ("utun4", "fd7a:115c:a1e0::9f01:2c3d"),
            ("utun4", "100.101.102.103"),
            // Another VPN's private address, and a public 100.x outside the shared range.
            ("utun2", "10.8.0.2"),
            ("utun3", "100.128.0.1"),
            // The shared range, but not on a tunnel.
            ("en5", "100.64.0.9"),
        ]
        #expect(CompanionReach.tailnetAddresses(interfaces) == ["100.101.102.103", "fd7a:115c:a1e0::9f01:2c3d"])
    }

    @Test func theSharedRangeIsTheWholeSlashTen() {
        #expect(CompanionReach.isTailnetIPv4("100.64.0.0"))
        #expect(CompanionReach.isTailnetIPv4("100.127.255.255"))
        #expect(!CompanionReach.isTailnetIPv4("100.63.255.255"))
        #expect(!CompanionReach.isTailnetIPv4("100.128.0.0"))
        #expect(!CompanionReach.isTailnetIPv4("100.64.0"))
        #expect(!CompanionReach.isTailnetIPv4("example.ts.net"))
    }

    @Test func listsAnAddressOnce() {
        let twice: [(name: String, address: String)] = [("utun1", "100.90.1.2"), ("utun5", "100.90.1.2")]
        #expect(CompanionReach.tailnetAddresses(twice) == ["100.90.1.2"])
    }

    @Test func aCodeCarriesWhereToReachTheMac() throws {
        let reach = CompanionReach(hosts: ["100.101.102.103", "fd7a:115c:a1e0::1"], port: 52_710)
        let code = CompanionPairingCode(macID: "m", macName: "MacBook Pro",
                                        key: .init(identity: "p", secret: CompanionKey.newSecret()), reach: reach)
        let read = try #require(CompanionPairingCode(url: code.url))
        #expect(read == code)
        #expect(read.reach == reach)
    }

    @Test func aCodeWithoutAddressesHasNoReach() throws {
        let code = CompanionPairingCode(macID: "m", macName: "Mac", key: .init(identity: "p", secret: CompanionKey.newSecret()),
                                        reach: CompanionReach(hosts: [], port: 52_710))
        #expect(!code.url.absoluteString.contains("port="))
        #expect(try #require(CompanionPairingCode(url: code.url)).reach == nil)
        // A port without a host, or a host without a port, is no way to reach it.
        var components = try #require(URLComponents(url: code.url, resolvingAgainstBaseURL: false))
        components.queryItems?.append(URLQueryItem(name: "port", value: "52710"))
        #expect(try #require(CompanionPairingCode(url: components.url!)).reach == nil)
        components.queryItems = components.queryItems?.filter { $0.name != "port" } ?? []
        components.queryItems?.append(URLQueryItem(name: "host", value: "100.64.0.1"))
        #expect(try #require(CompanionPairingCode(url: components.url!)).reach == nil)
    }

    @Test func theMessageCarriesItAndOlderOnesLackIt() throws {
        let reach = CompanionReach(hosts: ["100.101.102.103"], port: 52_710)
        let line = try CompanionMessage(reach: reach).line()
        #expect(try CompanionMessage(line: line).reach == reach)
        // A Mac from before sends no reach.
        let old = Data(#"{"version":1,"challenge":{"nonce":"AAAA"}}"#.utf8)
        #expect(try CompanionMessage(line: old).reach == nil)
    }
}

/// Which way the phone tries to reach its Mac.
@Suite("Companion route")
struct CompanionRouteTests {
    private let reach = CompanionReach(hosts: ["100.101.102.103", "fd7a:115c:a1e0::1"], port: 52_710)
    private let grace = CompanionRoute.bonjourGrace

    @Test func itsOwnServiceWheneverBonjourFindsIt() {
        #expect(CompanionRoute.next(own: "MacBook Pro", others: ["Studio"], reach: reach, attempts: 5, browsing: 0)
                == .service("MacBook Pro"))
    }

    @Test func bonjourGetsItsMomentFirst() {
        #expect(CompanionRoute.next(own: nil, others: [], reach: reach, attempts: 0, browsing: 1) == .wait(grace - 1))
    }

    @Test func thenTheTailnetAddressesInTurn() {
        #expect(CompanionRoute.next(own: nil, others: [], reach: reach, attempts: 0, browsing: grace)
                == .away(host: "100.101.102.103", port: 52_710))
        #expect(CompanionRoute.next(own: nil, others: [], reach: reach, attempts: 1, browsing: 60)
                == .away(host: "fd7a:115c:a1e0::1", port: 52_710))
    }

    /// On someone else's network, their Mimamori gets one try each, then the tailnet takes over.
    @Test func otherMacsOnceThenTheTailnet() {
        let others = ["Studio", "Office iMac"]
        #expect(CompanionRoute.next(own: nil, others: others, reach: reach, attempts: 0, browsing: 0) == .service("Studio"))
        #expect(CompanionRoute.next(own: nil, others: others, reach: reach, attempts: 1, browsing: 1) == .service("Office iMac"))
        #expect(CompanionRoute.next(own: nil, others: others, reach: reach, attempts: 2, browsing: 30)
                == .away(host: "100.101.102.103", port: 52_710))
        // Without a tailnet address, it keeps trying them, as before.
        #expect(CompanionRoute.next(own: nil, others: others, reach: nil, attempts: 3, browsing: 30) == .service("Office iMac"))
    }

    @Test func nowhereWithoutATailnetAddress() {
        #expect(CompanionRoute.next(own: nil, others: [], reach: nil, attempts: 0, browsing: 60) == .none)
        #expect(CompanionRoute.next(own: nil, others: [], reach: .init(hosts: [], port: 52_710), attempts: 0, browsing: 60) == .none)
    }
}
