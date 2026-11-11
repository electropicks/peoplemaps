import UIKit
import UniformTypeIdentifiers

/// PeopleMaps in the share sheet of Apple Maps, Google Maps, Safari, Messages and Notes. It reads nothing and contacts
/// nothing: it passes the shared link and text to the app as `peoplemaps://share?text=…` and closes. The app treats
/// that exactly like a paste into search (`SharedLink`, Docs/SEARCH.md "Shared links").
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handOff() }
    }

    private func handOff() async {
        let text = await sharedText()
        var parts = URLComponents(); parts.scheme = "peoplemaps"; parts.host = "share"
        parts.queryItems = [URLQueryItem(name: "text", value: text)]
        guard !text.isEmpty, let url = parts.url else { return finish() }
        if await openApp(url) { return finish() }
        // iOS has no supported call for a share extension to open its app, so this can stop working. The link is
        // then left on the clipboard, and the person is told where to put it.
        UIPasteboard.general.string = text
        let alert = UIAlertController(title: "Open PeopleMaps to continue", message: "The link was copied. Paste it into the search field in PeopleMaps.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.finish() })
        present(alert, animated: true)
    }

    /// The link first, then any words that came with it, one per line. Each kind is taken once: Maps sends the same
    /// link as both a URL and text.
    private func sharedText() async -> String {
        var lines: [String] = []
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for type in [UTType.url, UTType.plainText] {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                let item = try? await provider.loadItem(forTypeIdentifier: type.identifier)
                let found = (item as? URL)?.absoluteString ?? (item as? String) ?? (item as? NSAttributedString)?.string
                for line in (found ?? "").split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty && !lines.contains(line) {
                    lines.append(line)
                }
            }
        }
        return String(lines.joined(separator: "\n").prefix(4_000))
    }

    /// Asks the application object, found up the responder chain, to open the URL. `UIApplication.open` is not
    /// offered to extensions at compile time, so the message is sent by name.
    private func openApp(_ url: URL) async -> Bool {
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                return await withCheckedContinuation { done in open(current, selector, url as NSURL, [:] as NSDictionary) { done.resume(returning: $0) } }
            }
            responder = current.next
        }
        return false
    }

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}
