import AppKit
import SwiftUI

public struct OpenSourceCredit: Identifiable {
    public var id: String { name }
    public var name: String
    public var url: String
    public var author: String
    public var license: String
    public var usage: String

    public init(name: String, url: String, author: String, license: String, usage: String) {
        self.name = name
        self.url = url
        self.author = author
        self.license = license
        self.usage = usage
    }
}

public struct AboutApp {
    public var name: String
    public var summary: String
    public var repository: String
    public var upstreamRepository: String?
    public var maintainer: String?
    public var maintainerUrl: String?
    public var credits: [OpenSourceCredit]
    public var disclaimer: String

    public init(
        name: String,
        summary: String,
        repository: String,
        upstreamRepository: String? = nil,
        maintainer: String? = nil,
        maintainerUrl: String? = nil,
        credits: [OpenSourceCredit] = [],
        disclaimer: String = ""
    ) {
        self.name = name
        self.summary = summary
        self.repository = repository
        self.upstreamRepository = upstreamRepository
        self.maintainer = maintainer
        self.maintainerUrl = maintainerUrl
        self.credits = credits
        self.disclaimer = disclaimer
    }
}

public struct AboutView: View {
    public let app: AboutApp

    public var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.title2)
                        .bold()
                    Text("版本 1.1.3 (Audio & Mirror Fix)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text(app.summary)
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let maintainer = app.maintainer {
                    HStack {
                        Text("维护者:").bold()
                        if let mUrl = app.maintainerUrl, let url = URL(string: mUrl) {
                            Link(maintainer, destination: url)
                        } else {
                            Text(maintainer)
                        }
                    }
                    .font(.callout)
                }

                if let repoUrl = URL(string: app.repository) {
                    HStack {
                        Text("本仓库:").bold()
                        Link(app.repository, destination: repoUrl)
                    }
                    .font(.callout)
                }

                if let upstream = app.upstreamRepository, let upstreamUrl = URL(string: upstream) {
                    HStack {
                        Text("原仓库:").bold()
                        Link(upstream, destination: upstreamUrl)
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !app.disclaimer.isEmpty {
                Divider()
                Text(app.disclaimer)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !app.credits.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("致谢与开源项目:").font(.caption).bold()
                    ForEach(app.credits) { credit in
                        HStack {
                            if let url = URL(string: credit.url) {
                                Link(credit.name, destination: url)
                            } else {
                                Text(credit.name)
                            }
                            Text("(\(credit.usage)) - \(credit.author)")
                                .foregroundColor(.secondary)
                        }
                        .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

public final class AboutWindowController {
    public let app: AboutApp
    private var window: NSWindow?

    public init(app: AboutApp) {
        self.app = app
    }

    public func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AboutView(app: app))
        let win = NSWindow(contentViewController: hosting)
        win.title = "关于 \(app.name)"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func render(to url: URL) {}
}

public enum DebugLabels {
    public static var fileURL: URL?
    public static var windowPrefix: ((NSWindow) -> String?)?
    public static func start() {}
    public static func decorate(_ menu: NSMenu) {}
}
