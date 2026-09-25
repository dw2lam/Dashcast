import AppKit
import DashcastContracts
import Foundation
import Network
import Security

/// What `ensureDNSRecord()` did to the car hostname's A record.
public enum DNSRecordChange: String, Sendable {
    case created, updated, unchanged
}

/// Injection points. `live()` is the real Mac; tests swap in fakes.
struct NetworkEnvironment {
    var appSupportDir: URL
    var helperLayout: HelperLayout
    var secrets: SecretStore
    var session: URLSession
    var privilegedRunner: PrivilegedRunner
    var snapshot: () -> InterfaceSnapshot
    var fileExists: (String) -> Bool
    var isExecutable: (String) -> Bool
    var bundleResourceURL: URL?
    var defaults: UserDefaults
    var now: () -> Date
    /// nil → NWPathMonitor.
    var internetReachable: (() async -> Bool)?
    /// Names + bundle IDs of running apps (to spot SideDisplay).
    var runningApplicationNames: () -> [String]
    var openssl: String
    var readFile: (String) -> Data?
    /// Rewrites the helper's trigger file in place (launchd watches it).
    var touchFile: (String) -> Void
    var uid: UInt32
    var localDNSHost: String
    var localDNSPort: UInt16
    var dnsUpstreams: @Sendable () -> [NWEndpoint]

    @MainActor
    static func live() -> NetworkEnvironment {
        let resolvers = SystemResolvers(excluding: [DashcastDefaults.serviceAddress])
        return NetworkEnvironment(
            appSupportDir: DashcastDefaults.appSupportDir,
            helperLayout: .production,
            secrets: KeychainSecretStore(),
            session: URLSession(configuration: .ephemeral),
            privilegedRunner: AppleScriptPrivilegedRunner(),
            snapshot: { InterfaceScanner.snapshot() },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            bundleResourceURL: Bundle.main.resourceURL,
            defaults: .standard,
            now: { Date() },
            internetReachable: nil,
            runningApplicationNames: {
                NSWorkspace.shared.runningApplications.flatMap { [$0.localizedName, $0.bundleIdentifier].compactMap { $0 } }
            },
            openssl: PKCS12.opensslPath,
            readFile: { FileManager.default.contents(atPath: $0) },
            touchFile: { path in
                // In place (no atomic rename): the file's directory is root-owned.
                guard let handle = FileHandle(forWritingAtPath: path) else { return }
                defer { try? handle.close() }
                try? handle.truncate(atOffset: 0)
                try? handle.write(contentsOf: Data("\(Date().timeIntervalSince1970)\n".utf8))
            },
            uid: getuid(),
            localDNSHost: DashcastDefaults.serviceAddress,
            localDNSPort: LoopbackHelper.dnsPort,
            dnsUpstreams: { resolvers.endpoints() })
    }
}

/// Topology detection, the service-address (lo0 alias) helper, Cloudflare DNS, the Let's Encrypt
/// certificate, and travel-router setup.
@MainActor
public final class NetworkManager: NetworkManaging {
    public nonisolated static let defaultContactEmail = "inbox@davidlam.online"
    public nonisolated static let internetSharingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!
    public nonisolated static let helperPlistPath = LoopbackHelper.plistPath
    /// SideDisplay (a competing Tesla display app) also drives Internet Sharing.
    public nonisolated static let sideDisplayNote = "Quit SideDisplay before using Dashcast; both reconfigure Internet Sharing."
    nonisolated static let contactEmailKey = "dashcast.acmeContactEmail"
    nonisolated static let zone = "davidlam.online"
    nonisolated static let dnsCacheLifetime: TimeInterval = 300
    nonisolated static let dnsErrorCacheLifetime: TimeInterval = 30
    nonisolated static let renewalWindow: TimeInterval = 30 * 86_400

    let env: NetworkEnvironment
    private let pathWatcher: PathWatcher?
    private var dnsCache: (checkedAt: Date, ok: Bool, lifetime: TimeInterval)?
    private var expiryCache: (modified: Date, size: Int, expiry: Date?)?
    private var provisioning: Task<Void, Error>?

    /// Called on the main actor when the network path changes (interface up/down, new address).
    public var onNetworkChange: (() -> Void)?
    /// lego's output from the last provisioning run (for a log/details view).
    public private(set) var lastProvisioningLog = ""
    /// What public DNS said last time: the A record(s), "NXDOMAIN", or "error: …".
    public private(set) var lastDNSLookup: String?

    /// Names the local DNS responder answers with the service address.
    public nonisolated static let localDNSNames = [
        DashcastDefaults.hostname,
        "connman.vn.tesla.services",
        "connman.vn.cloud.tesla.cn",
        "captive.apple.com",
    ]
    /// The responder's port; the helper's pf rule maps the car's port-53 traffic onto it.
    public nonisolated static var localDNSPort: UInt16 { LoopbackHelper.dnsPort }
    /// Current network-helper version; older installs report `helperInstalled == false`.
    public nonisolated static var helperVersion: Int { LoopbackHelper.version }

    /// The local DNS responder is bound and answering.
    public private(set) var localDNSRunning = false
    /// Why the responder isn't running (e.g. the alias isn't on lo0 yet). Retried every 5 s.
    public private(set) var localDNSLastError: String?
    private var dnsServer: LocalDNSServer?
    private var localDNSBoundPort: UInt16?
    private var wantLocalServices = false
    private var dnsStarting = false
    private var dnsRetryTask: Task<Void, Never>?

    /// ACME account contact. Persisted in UserDefaults.
    public var acmeContactEmail: String {
        get {
            let stored = env.defaults.string(forKey: Self.contactEmailKey)?.trimmingCharacters(in: .whitespaces)
            return (stored?.isEmpty == false ? stored : nil) ?? Self.defaultContactEmail
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == Self.defaultContactEmail {
                env.defaults.removeObject(forKey: Self.contactEmailKey)
            } else {
                env.defaults.set(trimmed, forKey: Self.contactEmailKey)
            }
        }
    }

    public convenience init() {
        self.init(environment: .live())
    }

    init(environment: NetworkEnvironment) {
        env = environment
        pathWatcher = environment.internetReachable == nil ? PathWatcher() : nil
        pathWatcher?.setOnChange { [weak self] in
            Task { @MainActor in self?.networkDidChange() }
        }
    }

    private var paths: CertificatePaths { CertificatePaths(appSupport: env.appSupportDir) }

    private func networkDidChange() {
        if dnsCache?.ok == false { dnsCache = nil }
        if wantLocalServices, !localDNSRunning {
            Task { await attemptLocalDNSStart() }
        }
        onNetworkChange?()
    }

    // MARK: - Status

    public func currentStatus() async -> NetworkStatus {
        let topology = TopologyClassifier.classify(env.snapshot())
        var status = NetworkStatus()
        status.topology = topology.topology
        status.interfaceName = topology.interfaceName
        status.macLANAddress = topology.macLANAddress
        status.aliasActive = topology.aliasActive
        let helperVersion = installedHelperVersion()
        status.helperInstalled = (helperVersion ?? 0) >= LoopbackHelper.version
        status.hasCloudflareToken = hasCloudflareToken()
        status.internetReachable = await internetReachable()
        status.dnsRecordOK = await dnsRecordOK(networkAvailable: status.internetReachable)
        status.certificateExpiry = certificateExpiry()
        status.serviceAddressConflict = topology.conflict.map { "\($0.interface) \($0.address)/\($0.netmask)" }
        status.summary = Self.summary(status, topology: topology, now: env.now(), context: SummaryContext(
            sideDisplayRunning: isSideDisplayRunning(),
            localDNS: localDNSEndpoint,
            localDNSError: localDNSLastError,
            helperVersion: helperVersion,
            redirect: helperRuntimeStatus()))
        return status
    }

    /// "203.0.113.77:53530" while the local DNS responder runs.
    public var localDNSEndpoint: String? {
        guard localDNSRunning, let port = localDNSBoundPort else { return nil }
        return "\(env.localDNSHost):\(port)"
    }

    /// Interface whose subnet swallows the service address (see `summary`), e.g. "bridge100 203.0.113.1/255.255.255.0".
    public func serviceAddressConflict() -> String? {
        TopologyClassifier.classify(env.snapshot()).conflict.map { "\($0.interface) \($0.address)/\($0.netmask)" }
    }

    /// True when a SideDisplay process is running (it fights Dashcast over Internet Sharing).
    public func isSideDisplayRunning() -> Bool {
        env.runningApplicationNames().contains { $0.localizedCaseInsensitiveContains("sidedisplay") }
    }

    /// Default gateway of the primary interface (prefill for the router SSH host).
    public func defaultGateway() -> String? {
        env.snapshot().gateway
    }

    private func internetReachable() async -> Bool {
        if let probe = env.internetReachable { return await probe() }
        return await pathWatcher?.isSatisfied() ?? false
    }

    /// Public DNS (DoH to cloudflare-dns.com) resolves the car hostname to the service address.
    /// Cached for 5 minutes (30 s after an error).
    func dnsRecordOK(networkAvailable: Bool) async -> Bool {
        let now = env.now()
        if let cache = dnsCache, now.timeIntervalSince(cache.checkedAt) < cache.lifetime { return cache.ok }
        guard networkAvailable else { return dnsCache?.ok ?? false }
        do {
            let answer = try await DoHClient(session: env.session).queryA(DashcastDefaults.hostname)
            let ok = answer.addresses.contains(DashcastDefaults.serviceAddress)
            lastDNSLookup = answer.addresses.isEmpty
                ? (answer.status == 3 ? "NXDOMAIN" : "no A record (rcode \(answer.status))")
                : answer.addresses.joined(separator: ", ")
            dnsCache = (now, ok, Self.dnsCacheLifetime)
            return ok
        } catch {
            lastDNSLookup = "error: \(error.localizedDescription)"
            let previous = dnsCache?.ok ?? false
            dnsCache = (now, previous, Self.dnsErrorCacheLifetime)
            return previous
        }
    }

    /// Forget the cached DNS answer so the next status re-queries.
    public func invalidateDNSCheck() {
        dnsCache = nil
    }

    struct SummaryContext {
        var sideDisplayRunning = false
        /// Endpoint while the local DNS responder runs.
        var localDNS: String?
        var localDNSError: String?
        /// Installed helper version (nil = not installed). Defaults from `status.helperInstalled`.
        var helperVersion: Int??
        var redirect: LoopbackHelper.RuntimeStatus?
    }

    nonisolated static func summary(_ status: NetworkStatus, topology: TopologyResult, now: Date,
                                    context: SummaryContext = SummaryContext()) -> String {
        let address = DashcastDefaults.serviceAddress
        var parts = [topology.detail]
        if let conflict = topology.conflict {
            parts.append("Conflict: \(conflict.interface) is on \(conflict.address)/\(conflict.netmask), which contains Dashcast's \(address), so the car looks for it on the local network and can't connect. SideDisplay moves Internet Sharing onto 203.0.113.x; quit it, then turn Internet Sharing off and on so it returns to 192.168.2.x.")
        }
        if status.topology == .phoneHotspot {
            parts.append("Switch to Internet Sharing (A) or a travel router (B).")
        }
        if context.sideDisplayRunning {
            parts.append("SideDisplay is running. \(sideDisplayNote)")
        } else if status.topology == .macHotspot {
            parts.append(sideDisplayNote)
        }
        if !status.internetReachable { parts.append("No internet right now (the car link works without it).") }

        // Local DNS (localDNSRunning has no contract field, so it lives here).
        if let dns = context.localDNS {
            var line = "Local DNS running on \(dns)"
            if status.topology == .macHotspot {
                if let redirect = context.redirect, redirect.redirectActive {
                    line += "; the car's DNS is redirected to it"
                } else if let redirect = context.redirect, !redirect.anchorPointPresent {
                    line += "; pf has no com.apple anchor point, so the car's DNS can't be redirected"
                } else {
                    line += "; the car's DNS isn't redirected yet"
                }
            }
            parts.append(line + ".")
        } else if let error = context.localDNSError {
            parts.append("Local DNS off: \(error)")
        } else {
            parts.append("Local DNS off.")
        }

        // Required for any car link.
        var todo: [String] = []
        let installed = context.helperVersion ?? (status.helperInstalled ? LoopbackHelper.version : nil)
        if let installed {
            if installed < LoopbackHelper.version {
                todo.append("update the network helper (v\(installed) → v\(LoopbackHelper.version))")
            } else if !status.aliasActive {
                todo.append("\(address) isn't on lo0 (reinstall the helper or restart)")
            }
        } else {
            todo.append("install the network helper")
        }

        // Optional: HTTPS mode. Without it the car uses plain HTTP + WebRTC.
        var https: [String] = []
        let httpsReady = status.certificateExpiry.map { $0 > now } ?? false
        if let expiry = status.certificateExpiry {
            let days = Int(expiry.timeIntervalSince(now) / 86_400)
            if expiry <= now {
                https.append("renew the expired certificate")
            } else if expiry.timeIntervalSince(now) < renewalWindow {
                https.append("renew the certificate (expires in \(days) day\(days == 1 ? "" : "s"))")
            }
        } else {
            https.append("get a certificate")
        }
        if !status.hasCloudflareToken, !httpsReady || !https.isEmpty { https.insert("add a Cloudflare API token", at: 0) }
        if status.internetReachable, !status.dnsRecordOK { https.append("publish the DNS record for \(DashcastDefaults.hostname)") }

        if todo.isEmpty {
            switch status.topology {
            case .macHotspot, .router:
                parts.append(httpsReady
                             ? "Ready: open https://\(DashcastDefaults.hostname) in the car."
                             : "Ready (HTTP mode): open http://\(DashcastDefaults.hostname) or http://\(address) in the car.")
            case .phoneHotspot, .offline:
                parts.append("The helper and alias are ready.")
            }
        } else {
            parts.append("To do: " + todo.joined(separator: "; ") + ".")
        }
        if !https.isEmpty {
            let label = httpsReady ? "HTTPS:" : "For HTTPS (optional; until then the car uses HTTP + WebRTC):"
            parts.append("\(label) " + https.joined(separator: "; ") + ".")
        }
        return parts.joined(separator: " ")
    }

    /// Short user-facing guidance for a topology.
    public nonisolated static func explain(_ topology: Topology) -> String {
        let address = DashcastDefaults.serviceAddress
        switch topology {
        case .macHotspot:
            return "Mac hotspot (A): the car joins the Wi-Fi network your Mac shares and reaches \(address) through the Mac directly. Keep the Mac's uplink (iPhone USB or Ethernet) connected so the car also has internet, then open https://\(DashcastDefaults.hostname) in the car. \(sideDisplayNote)"
        case .router:
            return "Travel router (B): the Mac and the car share a router. The router needs a static route \(address)/32 via the Mac's LAN address, so use Router Setup to apply it over SSH, and reserve the Mac's DHCP lease in the GL.iNet admin page so the address stays put."
        case .phoneHotspot:
            return "A phone hotspot can't work, iPhone or Android: the car's gateway would be the phone, which has no route to \(address), and the addresses a phone hands out are private, which the Tesla browser blocks (iOS also isolates hotspot clients from each other). Use A: give the Mac the phone's internet over USB (iPhone) or Bluetooth (Android), turn on Internet Sharing over Wi-Fi and join the car to the Mac's network. Or use B: a travel router with a static route to the Mac, fed by the phone. \(sideDisplayNote)"
        case .offline:
            return "No network. Either turn on Internet Sharing so the Mac becomes the car's hotspot (A), or join the Mac and the car to the same travel router (B). \(sideDisplayNote)"
        }
    }

    // MARK: - Loopback helper

    /// Installs or upgrades the network helper (one admin prompt): lo0 alias + car DNS redirect.
    public func installLoopbackHelper() async throws {
        let layout = env.helperLayout
        let command = LoopbackHelper.installShellCommand(
            plist: try LoopbackHelper.plistData(layout: layout),
            script: Data(LoopbackHelper.script(layout: layout).utf8),
            uid: env.uid, layout: layout)
        _ = try await env.privilegedRunner.run(
            shellCommand: command,
            prompt: "Dashcast needs to add the address \(DashcastDefaults.serviceAddress) to this Mac and answer your car's DNS so it can connect.")
        guard let version = installedHelperVersion() else {
            throw NetworkError.helperDidNotApply("The helper wasn't installed at \(layout.plistPath).")
        }
        guard version >= LoopbackHelper.version else {
            throw NetworkError.helperDidNotApply("The helper at \(layout.plistPath) is still version \(version).")
        }
        guard TopologyClassifier.classify(env.snapshot()).aliasActive else {
            throw NetworkError.helperDidNotApply("The helper is installed but \(DashcastDefaults.serviceAddress) isn't on lo0 yet. Restart the Mac, or reinstall the helper.")
        }
        if wantLocalServices, !localDNSRunning {
            await attemptLocalDNSStart()
        } else if localDNSRunning {
            pokeHelper()
        }
    }

    public func uninstallLoopbackHelper() async throws {
        let layout = env.helperLayout
        _ = try await env.privilegedRunner.run(
            shellCommand: LoopbackHelper.uninstallShellCommand(layout: layout),
            prompt: "Dashcast needs to remove the address \(DashcastDefaults.serviceAddress) and its DNS redirect from this Mac.")
        if env.fileExists(layout.plistPath) || env.fileExists(layout.scriptPath) {
            throw NetworkError.helperDidNotApply("\(layout.plistPath) is still there.")
        }
        if TopologyClassifier.classify(env.snapshot()).aliasActive {
            throw NetworkError.helperDidNotApply("\(DashcastDefaults.serviceAddress) is still on lo0.")
        }
    }

    /// Installed helper version: nil = not installed, 1 = the original alias-only helper (or a
    /// damaged v2+ install missing its script). Compare with `NetworkManager.helperVersion`.
    public func installedHelperVersion() -> Int? {
        let layout = env.helperLayout
        guard env.fileExists(layout.plistPath) else { return nil }
        guard let data = env.readFile(layout.plistPath) else { return 1 }
        let version = LoopbackHelper.installedVersion(plist: data)
        if version >= 2, !env.fileExists(layout.scriptPath) { return 1 }
        return version
    }

    /// Installed but older than this build expects: offer "Update helper" (same install call).
    public var helperNeedsUpdate: Bool {
        guard let installed = installedHelperVersion() else { return false }
        return installed < LoopbackHelper.version
    }

    /// The helper's pf redirect of the car's DNS is in place (hotspot + responder running).
    public func isCarDNSRedirectActive() -> Bool {
        helperRuntimeStatus()?.redirectActive ?? false
    }

    func helperRuntimeStatus() -> LoopbackHelper.RuntimeStatus? {
        env.readFile(env.helperLayout.statusPath).map { LoopbackHelper.RuntimeStatus.parse(String(decoding: $0, as: UTF8.self)) }
    }

    /// Nudges the helper (via its WatchPaths trigger) to re-evaluate the DNS redirect now.
    private func pokeHelper() {
        env.touchFile(env.helperLayout.triggerPath)
    }

    // MARK: - Local services (DNS responder)

    /// Starts the local DNS responder on serviceAddress:53530. If it can't bind yet (the alias
    /// isn't on lo0 before the helper is installed), it retries every 5 s and on network changes.
    public func startLocalServices() async {
        wantLocalServices = true
        await attemptLocalDNSStart()
        if !localDNSRunning { scheduleLocalDNSRetry() }
    }

    public func stopLocalServices() async {
        wantLocalServices = false
        dnsRetryTask?.cancel()
        dnsRetryTask = nil
        dnsServer?.stop()
        dnsServer = nil
        localDNSBoundPort = nil
        let wasRunning = localDNSRunning
        localDNSRunning = false
        if wasRunning { pokeHelper() }
    }

    /// Queries answered so far (local, cached, forwarded, failed).
    public func localDNSStatistics() -> (queries: Int, local: Int, cached: Int, forwarded: Int, failed: Int)? {
        guard let stats = dnsServer?.stats else { return nil }
        return (stats.queries, stats.localAnswers, stats.cacheHits, stats.forwarded, stats.failures)
    }

    private func attemptLocalDNSStart() async {
        guard wantLocalServices, dnsServer == nil, !dnsStarting else { return }
        dnsStarting = true
        defer { dnsStarting = false }
        let server = LocalDNSServer(LocalDNSServer.Configuration(
            bindHost: env.localDNSHost,
            port: env.localDNSPort,
            localNames: Set(Self.localDNSNames.map { $0.lowercased() }),
            answerAddress: DashcastDefaults.serviceAddress,
            upstreams: env.dnsUpstreams))
        server.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in self?.localDNSDied(error) }
        }
        do {
            let port = try await server.start()
            guard wantLocalServices else {
                server.stop()
                return
            }
            dnsServer = server
            localDNSBoundPort = port
            localDNSRunning = true
            localDNSLastError = nil
            dnsRetryTask?.cancel()
            dnsRetryTask = nil
            pokeHelper()
        } catch {
            localDNSLastError = describeBindError(error)
        }
    }

    private func localDNSDied(_ error: Error) {
        dnsServer = nil
        localDNSBoundPort = nil
        localDNSRunning = false
        localDNSLastError = describeBindError(error)
        pokeHelper()
        if wantLocalServices { scheduleLocalDNSRetry() }
    }

    private func scheduleLocalDNSRetry() {
        guard dnsRetryTask == nil else { return }
        dnsRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.wantLocalServices, !self.localDNSRunning else { return }
                await self.attemptLocalDNSStart()
            }
        }
    }

    private func describeBindError(_ error: Error) -> String {
        if case NWError.posix(let code) = error {
            switch code {
            case .EADDRNOTAVAIL:
                return "\(env.localDNSHost) isn't on this Mac yet (install the network helper)."
            case .EADDRINUSE:
                return "port \(env.localDNSPort) on \(env.localDNSHost) is already in use."
            case .EACCES:
                return "not allowed to listen on \(env.localDNSHost):\(env.localDNSPort)."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Cloudflare

    public func setCloudflareToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try env.secrets.delete(SecretAccount.cloudflareToken)
        } else {
            try env.secrets.write(trimmed, account: SecretAccount.cloudflareToken)
        }
    }

    public func hasCloudflareToken() -> Bool {
        env.secrets.exists(SecretAccount.cloudflareToken)
    }

    private func cloudflareToken() throws -> String {
        guard let token = try env.secrets.read(SecretAccount.cloudflareToken), !token.isEmpty else {
            throw NetworkError.missingCloudflareToken
        }
        return token
    }

    /// Creates or corrects `car.davidlam.online A <serviceAddress>` (DNS only, TTL 300).
    @discardableResult
    public func ensureDNSRecord() async throws -> DNSRecordChange {
        try await ensureDNSRecord(token: cloudflareToken())
    }

    @discardableResult
    private func ensureDNSRecord(token: String) async throws -> DNSRecordChange {
        let client = CloudflareClient(token: token, session: env.session)
        let change = try await client.ensureARecord(zone: Self.zone, name: DashcastDefaults.hostname,
                                                    address: DashcastDefaults.serviceAddress)
        dnsCache = nil
        return change
    }

    // MARK: - Certificate

    public func provisionCertificate() async throws {
        if let running = provisioning {
            return try await running.value
        }
        let task = Task { @MainActor in try await self.runProvisioning() }
        provisioning = task
        defer { provisioning = nil }
        try await task.value
    }

    private func runProvisioning() async throws {
        let token = try cloudflareToken()
        try await ensureDNSRecord(token: token)

        guard let lego = Lego.locate(bundleResourceURL: env.bundleResourceURL, isExecutable: env.isExecutable) else {
            throw NetworkError.legoNotFound
        }
        let paths = self.paths
        try FileManager.default.createDirectory(at: paths.legoDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let version = try await ProcessRunner.run(lego.path, ["--version"], timeout: 15)
        let major = Lego.majorVersion(from: version.stdout + version.stderr) ?? 5
        let renew = env.fileExists(paths.legoCertificate.path)
        let arguments = Lego.arguments(major: major, email: acmeContactEmail, domain: DashcastDefaults.hostname,
                                       path: paths.legoDir.path, renew: renew)
        let result = try await ProcessRunner.run(
            lego.path, arguments,
            environment: Lego.environment(token: token, base: ProcessInfo.processInfo.environment),
            timeout: 600)
        lastProvisioningLog = result.tail(200)
        if result.timedOut { throw NetworkError.timedOut("Let's Encrypt issuance") }
        guard result.status == 0 else { throw NetworkError.legoFailed(result.tail()) }
        guard env.fileExists(paths.legoCertificate.path), env.fileExists(paths.legoKey.path) else {
            throw NetworkError.legoFailed("lego exited cleanly but \(paths.legoCertificate.path) is missing.\n\(result.tail())")
        }
        try await packagePKCS12()
    }

    /// lego PEM → PKCS#12 in the app-support directory, protected by a keychain-held passphrase.
    func packagePKCS12() async throws {
        let paths = self.paths
        _ = try await PKCS12.build(certificate: paths.legoCertificate, key: paths.legoKey,
                                   output: paths.pkcs12, passphrase: try p12Passphrase(),
                                   openssl: env.openssl)
        expiryCache = nil
    }

    private func p12Passphrase() throws -> String {
        if let existing = try env.secrets.read(SecretAccount.p12Passphrase), !existing.isEmpty {
            return existing
        }
        let fresh = RandomSecret.hex()
        try env.secrets.write(fresh, account: SecretAccount.p12Passphrase)
        return fresh
    }

    /// Renews when the stored certificate expires within 30 days (or has expired), and repackages
    /// the .p12 from lego's PEM if it's missing/unreadable. Never performs a first issuance, which is
    /// `provisionCertificate()`'s job. Returns true when anything was renewed or rebuilt.
    @discardableResult
    public func renewIfNeeded() async throws -> Bool {
        let now = env.now()
        let expiry = certificateExpiry()
        if let expiry, !PKCS12.needsRenewal(expiry: expiry, now: now, window: Self.renewalWindow) {
            return false
        }
        let paths = self.paths
        let hasLegoCertificate = env.fileExists(paths.legoCertificate.path)
        guard hasLegoCertificate || expiry != nil else { return false }

        if expiry == nil, hasLegoCertificate,
           let pemExpiry = PEM.leafExpiry(at: paths.legoCertificate),
           !PKCS12.needsRenewal(expiry: pemExpiry, now: now, window: Self.renewalWindow) {
            try await packagePKCS12()
            return true
        }
        try await provisionCertificate()
        return true
    }

    /// Expiry of the stored .p12's certificate (cached per file version).
    public func certificateExpiry() -> Date? {
        let url = paths.pkcs12
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            expiryCache = nil
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if let cache = expiryCache, cache.modified == modified, cache.size == size { return cache.expiry }
        guard let passphrase = try? env.secrets.read(SecretAccount.p12Passphrase),
              let data = try? Data(contentsOf: url),
              let imported = try? PKCS12.importIdentity(data, passphrase: passphrase) else {
            return nil
        }
        expiryCache = (modified, size, imported.notAfter)
        return imported.notAfter
    }

    public func tlsMaterial() -> TLSMaterial? {
        let url = paths.pkcs12
        guard let expiry = certificateExpiry(), expiry > env.now(),
              let passphrase = try? env.secrets.read(SecretAccount.p12Passphrase), !passphrase.isEmpty
        else { return nil }
        return TLSMaterial(pkcs12URL: url, passphrase: passphrase)
    }

    // MARK: - Router (topology B)

    public func routerSetupScript(macLANAddress: String) -> String {
        RouterSetup.script(macLANAddress: macLANAddress)
    }

    /// Runs `routerSetupScript` on the router over SSH (password auth via a temporary askpass
    /// helper, host key trusted on first use). `macLANAddress` defaults to the detected LAN address.
    /// Returns the router's output.
    @discardableResult
    public func applyRouterSetup(host: String, user: String = "root", password: String,
                                 macLANAddress: String? = nil) async throws -> String {
        let mac: String
        if let macLANAddress {
            mac = macLANAddress
        } else {
            let topology = TopologyClassifier.classify(env.snapshot())
            guard topology.topology == .router, let address = topology.macLANAddress else {
                throw NetworkError.invalidArgument("Connect the Mac to the travel router first. Right now: \(topology.detail)")
            }
            mac = address
        }
        guard IPv4.isValid(mac) else {
            throw NetworkError.invalidArgument("\"\(mac)\" isn't an IPv4 address.")
        }
        let askpass = try RouterSetup.writeAskpass()
        defer { try? FileManager.default.removeItem(at: askpass.directory) }
        let invocation = try RouterSetup.sshInvocation(host: host, user: user, password: password,
                                                       askpassPath: askpass.script.path,
                                                       baseEnvironment: ProcessInfo.processInfo.environment)
        let result = try await ProcessRunner.run(invocation.executable, invocation.arguments,
                                                 environment: invocation.environment,
                                                 stdin: Data(RouterSetup.script(macLANAddress: mac).utf8),
                                                 timeout: 90)
        if result.timedOut { throw NetworkError.timedOut("SSH to \(host)") }
        guard result.status == 0 else { throw NetworkError.sshFailed(result.tail()) }
        return result.tail(40)
    }

    // MARK: - Settings

    /// System Settings → General → Sharing (Internet Sharing lives there).
    public func openInternetSharingSettings() {
        NSWorkspace.shared.open(Self.internetSharingSettingsURL)
    }
}

/// Just enough PEM handling to read the leaf of lego's bundle.
enum PEM {
    static func certificates(in text: String) -> [SecCertificate] {
        var result: [SecCertificate] = []
        var remainder = Substring(text)
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        while let start = remainder.range(of: begin), let stop = remainder.range(of: end, range: start.upperBound..<remainder.endIndex) {
            let body = remainder[start.upperBound..<stop.lowerBound]
            if let der = Data(base64Encoded: String(body), options: .ignoreUnknownCharacters),
               let certificate = SecCertificateCreateWithData(nil, der as CFData) {
                result.append(certificate)
            }
            remainder = remainder[stop.upperBound...]
        }
        return result
    }

    static func leafExpiry(at url: URL) -> Date? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let leaf = certificates(in: text).first else { return nil }
        return SecCertificateCopyNotValidAfterDate(leaf) as Date?
    }
}
