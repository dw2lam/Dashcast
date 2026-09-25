import AppKit
import DashcastContracts
import SwiftUI
import UniformTypeIdentifiers

/// Secure mode on the user's own domain, as Form sections: shared by Settings → Network and the
/// sheet the Connection Guide and the Setup Assistant open.
struct OwnDomainSections: View {
    static let cloudflareTokensURL = URL(string: "https://dash.cloudflare.com/profile/api-tokens")!

    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var hostname = ""
    @State private var provider = OwnDomain.Provider.cloudflare

    var body: some View {
        let domain = model.state.network.domain
        let choosing = domain == nil || editing

        Section {
            if let domain, !editing {
                LabeledContent {
                    HStack(spacing: 10) {
                        Button("Change…") { edit(domain) }
                        ActionButton("Remove", busy: model.networkActivity == .savingDomain) { model.setOwnDomain(nil) }
                    }
                } label: {
                    Text(domain.hostname)
                    Text(domain.provider.title)
                }
            } else {
                TextField(text: $hostname, prompt: Text("car.yourdomain.com")) {
                    Text("Hostname")
                    hostnameNote
                }
                .onSubmit(save)
                Picker("DNS provider", selection: $provider) {
                    ForEach(OwnDomain.Provider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                HStack {
                    Spacer()
                    if editing {
                        Button("Cancel") { editing = false }
                    }
                    ActionButton("Use This Domain", busy: model.networkActivity == .savingDomain, action: save)
                        .disabled(!isValid)
                }
                NetworkErrorLabel()
            }
        } header: {
            Text("Secure Mode: Your Own Domain")
        } footer: {
            if choosing {
                Text("Optional. On a name you own, your Tesla connects over HTTPS, which unlocks WebCodecs, the lowest latency. Without one, Compatibility mode at http://\(DashcastDefaults.serviceAddress) works with no setup.")
                    .foregroundStyle(.secondary)
            }
        }

        if let domain, !editing {
            switch domain.provider {
            case .cloudflare: CloudflareSection(domain: domain)
            case .manual: ManualDNSSection(domain: domain)
            }
        }
    }

    /// nil while the field is empty.
    private var validation: Result<String, OwnDomain.InvalidHostname>? {
        hostname.trimmingCharacters(in: .whitespaces).isEmpty ? nil : OwnDomain.normalize(hostname)
    }

    private var isValid: Bool {
        if case .success = validation { return true }
        return false
    }

    @ViewBuilder
    private var hostnameNote: some View {
        if case .failure(let error) = validation {
            Text(error.reason).foregroundStyle(.red)
        } else {
            Text("A name on a domain you own. It will point to \(DashcastDefaults.serviceAddress), which exists only on this Mac.")
        }
    }

    private func edit(_ domain: OwnDomain) {
        hostname = domain.hostname
        provider = domain.provider
        editing = true
    }

    private func save() {
        guard case .success(let name) = validation else { return }
        model.setOwnDomain(OwnDomain(hostname: name, provider: provider))
        editing = false
    }
}

/// Cloudflare: a scoped API token, then one button for the A record and the Let's Encrypt certificate.
private struct CloudflareSection: View {
    let domain: OwnDomain
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var editingToken = false

    var body: some View {
        let status = model.state.network
        let activity = model.networkActivity

        Section {
            if status.hasCloudflareToken && !editingToken {
                LabeledContent {
                    Button("Replace…") { editingToken = true }
                } label: {
                    Text("API token")
                    StatusLabel("Saved in Keychain", .ok)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    InstructionLine(number: 1, text: "Open Cloudflare’s API Tokens page.")
                    InstructionLine(number: 2, text: "Click **Create Token** and use the **Edit zone DNS** template. Add the permission **Zone · Zone · Read**, and set **Zone Resources** to your domain.")
                    InstructionLine(number: 3, text: "Create the token, then paste it below.")
                    Link(destination: OwnDomainSections.cloudflareTokensURL) {
                        Label("Open Cloudflare API Tokens", systemImage: "arrow.up.forward.square")
                    }
                    .padding(.leading, 30)
                }
                .padding(.vertical, 2)
                LabeledContent {
                    HStack(spacing: 8) {
                        SecureField("API token", text: $token, prompt: Text("Paste token"))
                            .labelsHidden()
                            .frame(minWidth: 150)
                            .onSubmit(saveToken)
                        ActionButton("Save", busy: activity == .savingToken, action: saveToken)
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } label: {
                    Text("API token")
                    Text("Needs DNS Edit and Zone Read. Kept in your Keychain.")
                }
            }
            LabeledContent {
                if status.certificateExpiry == nil {
                    ActionButton("Get Certificate", busy: activity == .provisioning) { model.provisionCertificate() }
                        .disabled(!status.hasCloudflareToken)
                } else {
                    ActionButton("Renew", busy: activity == .renewing) { model.renewCertificate() }
                }
            } label: {
                Text("Certificate")
                CertificateStatus(expiry: status.certificateExpiry)
            }
            DNSRecordStatus(hostname: domain.hostname)
            NetworkErrorLabel()
        } header: {
            Text("Cloudflare")
        } footer: {
            Text("Get Certificate points \(domain.hostname) at \(DashcastDefaults.serviceAddress) (DNS only, not proxied), then gets a free Let’s Encrypt certificate. Both need an internet connection for a moment.")
                .foregroundStyle(.secondary)
        }
        .onChange(of: status.hasCloudflareToken) { _, has in
            if has { editingToken = false; token = "" }
        }
    }

    private func saveToken() {
        model.saveCloudflareToken(token)
    }
}

/// Any other DNS provider: the record to add by hand, and a certificate to import.
private struct ManualDNSSection: View {
    let domain: OwnDomain
    @Environment(AppModel.self) private var model
    @State private var pending: (data: Data, name: String)?
    @State private var passphrase = ""
    @State private var fileProblem: String?

    var body: some View {
        let status = model.state.network
        let busy = model.networkActivity == .importingCertificate

        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Add this record at your DNS provider:")
                    Spacer(minLength: 8)
                    CopyButton(text: "\(domain.hostname). 300 IN A \(DashcastDefaults.serviceAddress)", label: "Copy")
                        .controlSize(.small)
                }
                DNSRecordTable(hostname: domain.hostname)
            }
            .padding(.vertical, 2)
            DNSRecordStatus(hostname: domain.hostname)
            LabeledContent {
                ActionButton(status.certificateExpiry == nil ? "Import…" : "Replace…", busy: busy, action: choose)
                    .disabled(pending != nil)
            } label: {
                Text("Certificate")
                CertificateStatus(expiry: status.certificateExpiry)
            }
            if let pending {
                LabeledContent {
                    HStack(spacing: 8) {
                        SecureField("Passphrase", text: $passphrase, prompt: Text("Passphrase"))
                            .labelsHidden()
                            .frame(minWidth: 130)
                            .onSubmit(importPending)
                        Button("Cancel") { self.pending = nil }
                        Button("Import", action: importPending)
                    }
                } label: {
                    Text("Passphrase")
                    Text("For \(pending.name).")
                }
            }
            if let fileProblem {
                Label(fileProblem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            NetworkErrorLabel()
        } header: {
            Text("Your DNS Provider")
        } footer: {
            Text("Import a certificate for \(domain.hostname): a .p12 file with its passphrase, or PEM certificate and key files. Automatic certificates (DNS-01) work with Cloudflare only for now.")
                .foregroundStyle(.secondary)
        }
    }

    private func choose() {
        fileProblem = nil
        let panel = NSOpenPanel()
        panel.title = "Import Certificate"
        panel.message = "Choose a .p12 file, or the certificate and private key (PEM) for \(domain.hostname)."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = CertificateFiles.contentTypes
        guard panel.runModal() == .OK else { return }
        switch CertificateFiles.load(panel.urls) {
        case .success(.pkcs12(let data, let name)):
            passphrase = ""
            pending = (data, name)
        case .success(.pem(let certificate, let key)):
            model.importCertificate(.pem(certificate: certificate, key: key))
        case .failure(let problem):
            fileProblem = problem.message
        }
    }

    private func importPending() {
        guard let pending else { return }
        model.importCertificate(.pkcs12(pending.data, passphrase: passphrase))
        self.pending = nil
        passphrase = ""
    }
}

// MARK: - Pieces

/// The A record exactly as a DNS provider's form asks for it.
struct DNSRecordTable: View {
    let hostname: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                ForEach(["Type", "Name", "Value", "Proxy"], id: \.self) { Text($0) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            GridRow {
                Text("A")
                Text(hostname)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(DashcastDefaults.serviceAddress)
                    .fixedSize()
                Text("DNS only")
                    .font(.callout)
                    .fixedSize()
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator)
        }
    }
}

/// Whether public DNS already sends the hostname to the service address.
private struct DNSRecordStatus: View {
    let hostname: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.state.network
        LabeledContent {
            EmptyView()
        } label: {
            Text("DNS record")
            if status.dnsRecordOK {
                StatusLabel("\(hostname) → \(DashcastDefaults.serviceAddress)", .ok)
            } else if status.internetReachable {
                StatusLabel("Not published yet", .neutral)
            } else {
                StatusLabel("Can’t check without internet", .neutral)
            }
        }
    }
}

struct CertificateStatus: View {
    let expiry: Date?

    var body: some View {
        if let expiry {
            let date = expiry.formatted(date: .abbreviated, time: .omitted)
            if expiry <= Date() {
                StatusLabel("Expired \(date)", .error)
            } else {
                StatusLabel("Valid until \(date)", expiry.timeIntervalSinceNow < 14 * 86_400 ? .warning : .ok)
            }
        } else {
            StatusLabel("None", .neutral)
        }
    }
}

private struct InstructionLine: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.dashAccent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.dashAccent.opacity(0.14)))
            Text(AttributedString(inlineMarkdown: text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct NetworkErrorLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.networkError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

/// The own-domain settings on their own: the Connection Guide's and the Setup Assistant's way in.
struct OwnDomainSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                OwnDomainSections()
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if model.networkActivity != nil && model.networkActivity != .refreshing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
        .tint(.dashAccent)
        .task { await model.refreshNetwork() }
    }
}

// MARK: - Certificate files

/// What the user picked in the Import panel.
enum CertificateFiles {
    enum Loaded: Equatable {
        case pkcs12(Data, name: String)
        case pem(certificate: Data, key: Data)
    }

    struct Problem: Error, Equatable {
        let message: String
    }

    static let contentTypes: [UTType] = [.pkcs12, .x509Certificate]
        + ["pfx", "pem", "crt", "cer", "key"].compactMap { UTType(filenameExtension: $0) }

    /// A .p12/.pfx wins; otherwise the PEM files' certificates (in order, leaf first) and private key.
    static func load(_ urls: [URL]) -> Result<Loaded, Problem> {
        if let url = urls.first(where: { ["p12", "pfx"].contains($0.pathExtension.lowercased()) }) {
            guard let data = try? Data(contentsOf: url) else {
                return .failure(Problem(message: "Couldn’t read \(url.lastPathComponent)."))
            }
            return .success(.pkcs12(data, name: url.lastPathComponent))
        }
        return parse(urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) })
    }

    static func parse(_ texts: [String]) -> Result<Loaded, Problem> {
        let blocks = texts.flatMap(pemBlocks)
        let certificates = blocks.filter { $0.label == "CERTIFICATE" }
        let keys = blocks.filter { $0.label.hasSuffix("PRIVATE KEY") }
        if keys.contains(where: { $0.label.hasPrefix("ENCRYPTED") || $0.text.contains("Proc-Type: 4,ENCRYPTED") }) {
            return .failure(Problem(message: "That private key is password-protected. Export it without a password, or use a .p12 file."))
        }
        guard !certificates.isEmpty, let key = keys.first else {
            return .failure(Problem(message: "Choose the certificate and its private key (PEM), or one .p12 file."))
        }
        let chain = certificates.map(\.text).joined(separator: "\n") + "\n"
        return .success(.pem(certificate: Data(chain.utf8), key: Data((key.text + "\n").utf8)))
    }

    /// Every `-----BEGIN X----- … -----END X-----` block, in order.
    static func pemBlocks(_ text: String) -> [(label: String, text: String)] {
        var blocks: [(label: String, text: String)] = []
        var rest = Substring(text)
        while let begin = rest.range(of: "-----BEGIN "),
              let labelEnd = rest.range(of: "-----", range: begin.upperBound..<rest.endIndex) {
            let label = String(rest[begin.upperBound..<labelEnd.lowerBound])
            guard let end = rest.range(of: "-----END \(label)-----", range: labelEnd.upperBound..<rest.endIndex) else { break }
            blocks.append((label, String(rest[begin.lowerBound..<end.upperBound])))
            rest = rest[end.upperBound...]
        }
        return blocks
    }
}
