import SwiftUI
import WebKit
import Security
import UIKit

private struct PersistedCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
    let isSecure: Bool
    let version: Int
    let portList: [Int]?

    init(cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresDate = cookie.expiresDate
        isSecure = cookie.isSecure
        version = cookie.version
        portList = cookie.portList?.map { $0.intValue }
    }

    func makeHTTPCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path,
            .version: String(version)
        ]

        if let expiresDate {
            properties[.expires] = expiresDate
        }

        if isSecure {
            properties[.secure] = "TRUE"
        }

        if let portList, !portList.isEmpty {
            properties[.port] = portList.map(String.init).joined(separator: ",")
        }

        return HTTPCookie(properties: properties)
    }
}

struct DriveWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(startURL: url)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Bridge nativo per i download. Il frontend MyDrive passa qui URL e nome
        // del file; l'app scarica davvero i byte con URLSession e poi apre il
        // selettore File di iOS con un file locale reale.
        configuration.userContentController.add(context.coordinator, name: "myDriveDownload")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true
        webView.backgroundColor = .systemBackground

        context.coordinator.webView = webView
        context.coordinator.installStatusView(on: webView)
        context.coordinator.prepareCookiePersistence(using: webView.configuration.websiteDataStore.httpCookieStore)
        context.coordinator.restoreCookiesAndLoadStartPage()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver, WKScriptMessageHandler, UIDocumentPickerDelegate, WKDownloadDelegate {
        weak var webView: WKWebView?
        private let startURL: URL
        private weak var statusView: UIView?
        private weak var statusLabel: UILabel?
        private weak var retryButton: UIButton?
        private var cookieStore: WKHTTPCookieStore?
        private var lifecycleObservers: [NSObjectProtocol] = []

        // Dopo che MyDrive si è caricata almeno una volta, un errore di una
        // navigazione secondaria (per esempio il passaggio al pannello iOS
        // "Salva su File") NON deve sostituire la pagina con la schermata
        // "server non raggiungibile".
        private var hasLoadedPageSuccessfully = false
        private var isAppActive = UIApplication.shared.applicationState == .active
        private var webContentProcessNeedsReload = false

        // Download nativo iOS. Tenere il file in una directory temporanea reale
        // è fondamentale: navigator.share/blob dentro WKWebView può mostrare
        // "Download avviato" senza materializzare alcun file salvabile.
        private var nativeDownloadTask: URLSessionDownloadTask?
        private var pendingExportURL: URL?
        private var pendingExportFileName: String?
        private var wkDownloadDestinations: [ObjectIdentifier: URL] = [:]

        private let cookieKeychainService = (Bundle.main.bundleIdentifier ?? "MyDrive") + ".cookies"
        private let cookieKeychainAccount = "WKWebViewCookies"

        init(startURL: URL) {
            self.startURL = startURL
            super.init()
        }

        deinit {
            nativeDownloadTask?.cancel()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "myDriveDownload")
            cookieStore?.remove(self)
            lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        // MARK: - Cookie persistence

        func prepareCookiePersistence(using store: WKHTTPCookieStore) {
            cookieStore = store
            store.add(self)

            // Manteniamo anche HTTPCookieStorage sincronizzato. Non e' lo store
            // usato direttamente da WKWebView, ma ci offre un secondo punto di
            // persistenza utile per le richieste iniziali e per eventuali URLSession.
            HTTPCookieStorage.shared.cookieAcceptPolicy = .always

            lifecycleObservers.append(
                NotificationCenter.default.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.persistCurrentCookies()
                }
            )

            lifecycleObservers.append(
                NotificationCenter.default.addObserver(
                    forName: UIApplication.willResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.isAppActive = false
                    self?.persistCurrentCookies()
                }
            )

            lifecycleObservers.append(
                NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.isAppActive = true

                    // Tornando dal foglio Condividi / "Salva su File" non
                    // ricarichiamo MyDrive e non mostriamo errori transitori.
                    // La WebView resta esattamente sulla pagina già aperta.
                    if self.hasLoadedPageSuccessfully {
                        self.hideStatus()
                    }

                    // Se iOS ha realmente terminato il processo WebKit mentre
                    // l'app era in background, ricarichiamo soltanto al ritorno.
                    if self.webContentProcessNeedsReload {
                        self.webContentProcessNeedsReload = false
                        if self.webView?.url != nil {
                            self.webView?.reload()
                        } else {
                            self.loadStartPage()
                        }
                    }
                }
            )

            lifecycleObservers.append(
                NotificationCenter.default.addObserver(
                    forName: UIApplication.willTerminateNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.persistCurrentCookies()
                }
            )
        }

        func restoreCookiesAndLoadStartPage() {
            guard let store = cookieStore else {
                loadStartPage()
                return
            }

            let now = Date()
            let savedCookies = readCookiesFromKeychain().filter { cookie in
                guard let expiration = cookie.expiresDate else { return true }
                return expiration > now
            }

            // Ripristina i cookie anche nello storage Foundation.
            savedCookies.forEach { HTTPCookieStorage.shared.setCookie($0) }

            guard !savedCookies.isEmpty else {
                // Potrebbero comunque esserci cookie permanenti gia' conservati
                // automaticamente dal WKWebsiteDataStore di iOS.
                loadStartPageUsingCookiesFromStore()
                return
            }

            isRestoringCookies = true
            let group = DispatchGroup()

            for cookie in savedCookies {
                group.enter()
                store.setCookie(cookie) {
                    group.leave()
                }
            }

            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                self.isRestoringCookies = false
                self.loadStartPageUsingCookiesFromStore(fallback: savedCookies)
            }
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !isRestoringCookies else { return }
            persistCurrentCookies()
        }

        private var isRestoringCookies = false

        private func persistCurrentCookies() {
            guard let store = cookieStore else { return }

            store.getAllCookies { [weak self] cookies in
                guard let self else { return }

                // Sincronizza sempre anche lo storage Foundation.
                cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
                self.writeCookiesToKeychain(cookies)
            }
        }

        private func writeCookiesToKeychain(_ cookies: [HTTPCookie]) {
            // Non serializziamo cookie.properties direttamente: puo' contenere
            // tipi che PropertyListSerialization non accetta e far fallire
            // silenziosamente l'intero salvataggio. Salviamo solo campi sicuri.
            let snapshots = cookies.map(PersistedCookie.init(cookie:))

            guard let data = try? JSONEncoder().encode(snapshots) else {
                return
            }

            let baseQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: cookieKeychainService,
                kSecAttrAccount as String: cookieKeychainAccount
            ]

            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]

            let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var addQuery = baseQuery
                attributes.forEach { addQuery[$0.key] = $0.value }
                SecItemAdd(addQuery as CFDictionary, nil)
            }
        }

        private func readCookiesFromKeychain() -> [HTTPCookie] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: cookieKeychainService,
                kSecAttrAccount as String: cookieKeychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else {
                return []
            }

            // Nuovo formato robusto JSON. Se il vecchio formato era stato
            // salvato correttamente, proviamo comunque a migrarlo.
            if let snapshots = try? JSONDecoder().decode([PersistedCookie].self, from: data) {
                return snapshots.compactMap { $0.makeHTTPCookie() }
            }

            if let raw = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [[String: Any]] {
                return raw.compactMap { dictionary in
                    var properties: [HTTPCookiePropertyKey: Any] = [:]
                    for (key, value) in dictionary {
                        properties[HTTPCookiePropertyKey(rawValue: key)] = value
                    }
                    return HTTPCookie(properties: properties)
                }
            }

            return []
        }

        private func loadStartPageUsingCookiesFromStore(fallback: [HTTPCookie] = []) {
            guard let store = cookieStore else {
                loadStartPage(cookies: fallback)
                return
            }

            store.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let availableCookies = cookies.isEmpty ? fallback : cookies
                DispatchQueue.main.async {
                    self.loadStartPage(cookies: availableCookies)
                }
            }
        }

        private func cookiesForStartURL(from cookies: [HTTPCookie]) -> [HTTPCookie] {
            guard let host = startURL.host?.lowercased() else { return [] }
            let requestPath = startURL.path.isEmpty ? "/" : startURL.path
            let isHTTPS = startURL.scheme?.lowercased() == "https"
            let now = Date()

            return cookies.filter { cookie in
                if let expiration = cookie.expiresDate, expiration <= now {
                    return false
                }

                if cookie.isSecure && !isHTTPS {
                    return false
                }

                let cookieDomain = cookie.domain
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))

                let domainMatches = host == cookieDomain || host.hasSuffix("." + cookieDomain)
                guard domainMatches else { return false }

                let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
                return requestPath.hasPrefix(cookiePath) || cookiePath == "/"
            }
        }

        // MARK: - Navigation

        func loadStartPage(cookies: [HTTPCookie] = []) {
            hideStatus()
            var request = URLRequest(
                url: startURL,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 15
            )

            // Fallback importante: oltre a reinserire i cookie nel WKHTTPCookieStore,
            // li mandiamo esplicitamente nella primissima richiesta. In questo modo
            // il server vede gia' PHPSESSID / cookie di login prima di qualsiasi redirect.
            let matchingCookies = cookiesForStartURL(from: cookies)
            if !matchingCookies.isEmpty {
                let headers = HTTPCookie.requestHeaderFields(with: matchingCookies)
                for (field, value) in headers {
                    request.setValue(value, forHTTPHeaderField: field)
                }
            }

            webView?.load(request)
        }

        func installStatusView(on webView: WKWebView) {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .systemBackground
            container.isHidden = true

            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()

            let label = UILabel()
            label.text = "MyDrive non riesce a raggiungere il server.\nControlla che la VPN/Tailscale sia attiva."
            label.textAlignment = .center
            label.numberOfLines = 0
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .body)

            var config = UIButton.Configuration.filled()
            config.title = "Riprova"
            config.cornerStyle = .medium
            let button = UIButton(configuration: config)
            button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

            let stack = UIStackView(arrangedSubviews: [spinner, label, button])
            stack.axis = .vertical
            stack.spacing = 18
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(stack)
            webView.addSubview(container)

            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
                container.topAnchor.constraint(equalTo: webView.topAnchor),
                container.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
                stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 28),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28)
            ])

            statusView = container
            statusLabel = label
            retryButton = button
        }

        @objc private func retryTapped() {
            loadStartPage()
        }

        private func showStatus() {
            statusView?.isHidden = false
            if let statusView {
                webView?.bringSubviewToFront(statusView)
            }
        }

        private func hideStatus() {
            statusView?.isHidden = true
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            hideStatus()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasLoadedPageSuccessfully = true
            hideStatus()
            persistCurrentCookies()
            installNativeDownloadBridge(in: webView)
        }

        private func isExpectedTransientNavigationError(_ error: NSError) -> Bool {
            // -999 = NSURLErrorCancelled. iOS lo genera normalmente quando una
            // navigazione viene sostituita/annullata da un pannello di sistema,
            // inclusi Share Sheet e "Salva su File". Non è un errore server.
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                return true
            }

            // WebKitErrorDomain 102 = "Frame load interrupted" / cambio di
            // policy. Può comparire quando WebKit consegna un file ad iOS anziché
            // visualizzarlo come pagina. Anche questo non significa VPN offline.
            if error.domain == "WebKitErrorDomain" && error.code == 102 {
                return true
            }

            return false
        }

        private func handleNavigationFailure(_ error: Error) {
            let nsError = error as NSError

            // Errori normali durante download, Share Sheet o cambio app: ignorali.
            if isExpectedTransientNavigationError(nsError) {
                if hasLoadedPageSuccessfully { hideStatus() }
                return
            }

            // Mentre iOS sta presentando File/Share Sheet l'app può essere
            // temporarily inactive. Non trasformiamo quel passaggio in un errore.
            guard isAppActive, UIApplication.shared.applicationState == .active else {
                return
            }

            // Se MyDrive era già caricata, manteniamo la pagina corrente.
            // Un errore di una richiesta/navigazione successiva non deve mai
            // coprire tutto il desktop con la schermata offline.
            guard !hasLoadedPageSuccessfully else {
                hideStatus()
                return
            }

            // La schermata VPN/server offline resta quindi riservata al solo
            // fallimento del caricamento iniziale dell'app.
            showStatus()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(error)
        }

        // MARK: - Download nativi iOS

        private func installNativeDownloadBridge(in webView: WKWebView) {
            let script = #"""
            (() => {
              const handler = window.webkit?.messageHandlers?.myDriveDownload;
              if (!handler) return false;

              const absoluteURL = (value) => {
                try { return new URL(String(value || ''), window.location.href).href; }
                catch (_) { return String(value || ''); }
              };

              const sendToNative = (url, name = '') => {
                const href = absoluteURL(url);
                if (!href) return false;
                try {
                  handler.postMessage({ url: href, name: String(name || '') });
                  return true;
                } catch (error) {
                  console.warn('MyDrive download bridge:', error);
                  return false;
                }
              };

              window.__myDriveNativeIOSDownloadBridgeInstalled = true;
              window.__myDriveNativeIOSDownload = true;

              // Le funzioni usate dal desktop e dal Viewer passano direttamente
              // al codice Swift. Niente Blob URL / navigator.share in WKWebView.
              window.__myDriveSaveFileOnMobile = async (url, fileName = '') =>
                sendToNative(url, fileName);
              window.__myDriveTriggerDownload = (url, fileName = '') =>
                sendToNative(url, fileName);

              // Fallback per eventuali link download non instradati dalle funzioni
              // MyDrive. Non interferisce con i link normali.
              if (!window.__myDriveNativeIOSDownloadClickHook) {
                window.__myDriveNativeIOSDownloadClickHook = true;
                document.addEventListener('click', (event) => {
                  const target = event.target instanceof Element ? event.target : null;
                  const link = target?.closest?.('a[download]');
                  if (!link) return;
                  const href = link.getAttribute('href');
                  if (!href || href.startsWith('blob:')) return;
                  event.preventDefault();
                  event.stopPropagation();
                  if (event.stopImmediatePropagation) event.stopImmediatePropagation();
                  const name = link.getAttribute('download') || '';
                  try { window.__myDriveShowDownloadStarted?.(name); } catch (_) {}
                  sendToNative(href, name);
                }, true);
              }

              return true;
            })();
            """#

            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    print("MyDrive: impossibile installare bridge download: \(error.localizedDescription)")
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "myDriveDownload",
                  let payload = message.body as? [String: Any],
                  let rawURL = payload["url"] as? String,
                  !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            let requestedName = (payload["name"] as? String) ?? ""
            guard let baseURL = webView?.url ?? Optional(startURL),
                  let targetURL = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL else {
                presentDownloadError("Link di download non valido.")
                return
            }

            startNativeDownload(from: targetURL, requestedName: requestedName)
        }

        private func startNativeDownload(from url: URL, requestedName: String) {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                presentDownloadError("Questo tipo di link non può essere scaricato.")
                return
            }

            // I download MyDrive devono restare sullo stesso server già aperto.
            // Evita che un link esterno possa essere trasformato in download nativo.
            if let currentHost = (webView?.url ?? startURL).host?.lowercased(),
               let targetHost = url.host?.lowercased(),
               currentHost != targetHost {
                presentDownloadError("Il file non appartiene al server MyDrive aperto.")
                return
            }

            guard nativeDownloadTask == nil, pendingExportURL == nil else {
                presentDownloadError("C'è già un download in corso. Completa prima quello attuale.")
                return
            }

            let begin: ([HTTPCookie]) -> Void = { [weak self] cookies in
                guard let self else { return }
                var request = URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: 120
                )

                let matchingCookies = self.cookies(for: url, from: cookies)
                if !matchingCookies.isEmpty {
                    let headers = HTTPCookie.requestHeaderFields(with: matchingCookies)
                    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                }
                if let referer = self.webView?.url?.absoluteString {
                    request.setValue(referer, forHTTPHeaderField: "Referer")
                }

                let task = URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
                    guard let self else { return }

                    DispatchQueue.main.async {
                        self.nativeDownloadTask = nil
                    }

                    if let error {
                        DispatchQueue.main.async {
                            self.presentDownloadError("Download non riuscito: \(error.localizedDescription)")
                        }
                        return
                    }

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode),
                          let temporaryURL else {
                        let status = (response as? HTTPURLResponse)?.statusCode
                        DispatchQueue.main.async {
                            self.presentDownloadError(status.map { "Download non riuscito (HTTP \($0))." } ?? "Il server non ha restituito un file valido.")
                        }
                        return
                    }

                    let suggestedName = response?.suggestedFilename ?? ""
                    let fileName = self.safeFileName(
                        requestedName.isEmpty ? suggestedName : requestedName,
                        fallbackURL: url
                    )

                    do {
                        let destination = try self.persistDownloadedTemporaryFile(temporaryURL, fileName: fileName)
                        DispatchQueue.main.async {
                            self.pendingExportURL = destination
                            self.pendingExportFileName = fileName
                            self.presentFileExporter(for: destination)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.presentDownloadError("Il file è stato ricevuto ma non può essere preparato per il salvataggio: \(error.localizedDescription)")
                        }
                    }
                }

                self.nativeDownloadTask = task
                task.resume()
            }

            if let cookieStore {
                cookieStore.getAllCookies { cookies in
                    DispatchQueue.main.async { begin(cookies) }
                }
            } else {
                begin(HTTPCookieStorage.shared.cookies(for: url) ?? [])
            }
        }

        private func cookies(for url: URL, from cookies: [HTTPCookie]) -> [HTTPCookie] {
            guard let host = url.host?.lowercased() else { return [] }
            let requestPath = url.path.isEmpty ? "/" : url.path
            let isHTTPS = url.scheme?.lowercased() == "https"
            let now = Date()

            return cookies.filter { cookie in
                if let expiration = cookie.expiresDate, expiration <= now { return false }
                if cookie.isSecure && !isHTTPS { return false }

                let domain = cookie.domain
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard host == domain || host.hasSuffix("." + domain) else { return false }

                let path = cookie.path.isEmpty ? "/" : cookie.path
                return requestPath.hasPrefix(path) || path == "/"
            }
        }

        private func safeFileName(_ preferred: String, fallbackURL: URL) -> String {
            var name = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = fallbackURL.lastPathComponent }
            if name.isEmpty { name = "download" }

            let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
            name = name.components(separatedBy: forbidden).joined(separator: "_")
            while name.hasPrefix(".") { name.removeFirst() }
            return name.isEmpty ? "download" : String(name.prefix(220))
        }

        private func persistDownloadedTemporaryFile(_ source: URL, fileName: String) throws -> URL {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("MyDriveNativeDownloads", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(fileName, isDirectory: false)
            try fm.moveItem(at: source, to: destination)
            return destination
        }

        private func presentFileExporter(for fileURL: URL) {
            guard let webView, let presenter = topViewController(for: webView) else {
                cleanupPendingExport()
                presentDownloadError("Impossibile aprire l'app File.")
                return
            }

            // Questo è un file locale vero, non un Blob della WebView. iOS copia
            // realmente il file nella cartella scelta dall'utente.
            let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            picker.delegate = self
            picker.modalPresentationStyle = .formSheet
            presenter.present(picker, animated: true)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let name = pendingExportFileName
            cleanupPendingExport()
            if let name, !name.isEmpty {
                showWebToast("File salvato: \(name)")
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            cleanupPendingExport()
        }

        private func cleanupPendingExport() {
            guard let fileURL = pendingExportURL else {
                pendingExportFileName = nil
                return
            }
            pendingExportURL = nil
            pendingExportFileName = nil
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        private func presentDownloadError(_ message: String) {
            guard let webView, let presenter = topViewController(for: webView) else { return }
            let alert = UIAlertController(title: "Download non riuscito", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(alert, animated: true)
        }

        private func showWebToast(_ message: String) {
            guard let webView,
                  let data = try? JSONSerialization.data(withJSONObject: [message]),
                  let json = String(data: data, encoding: .utf8),
                  json.count >= 2 else { return }
            let literal = String(json.dropFirst().dropLast())
            webView.evaluateJavaScript("window.showToastImmediate?.(\(literal));")
        }

        // Fallback WKDownload: se qualche link attachment sfugge al bridge JS,
        // WebKit lo consegna comunque al codice nativo invece di navigarlo.
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let name = safeFileName(suggestedFilename, fallbackURL: response.url ?? startURL)
            do {
                let fm = FileManager.default
                let root = fm.temporaryDirectory.appendingPathComponent("MyDriveWKDownloads", isDirectory: true)
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(name)
                wkDownloadDestinations[ObjectIdentifier(download)] = destination
                completionHandler(destination)
            } catch {
                completionHandler(nil)
                presentDownloadError("Impossibile preparare il download: \(error.localizedDescription)")
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let destination = wkDownloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            pendingExportURL = destination
            pendingExportFileName = destination.lastPathComponent
            presentFileExporter(for: destination)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let destination = wkDownloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            }
            if (error as NSError).code != NSURLErrorCancelled {
                presentDownloadError("Download non riuscito: \(error.localizedDescription)")
            }
        }

        // Gestisce link con target="_blank" e chiamate JavaScript window.open().
        // WKWebView, a differenza di Safari, non apre automaticamente una nuova
        // finestra: carichiamo quindi la destinazione nello stesso WebView.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else {
                return nil
            }

            if let scheme = url.scheme?.lowercased(),
               scheme != "http" && scheme != "https" {
                UIApplication.shared.open(url)
                return nil
            }

            webView.load(navigationAction.request)
            return nil
        }

        // Fallback per alcune navigazioni aperte senza frame di destinazione.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if #available(iOS 14.5, *), navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }

            if navigationAction.targetFrame == nil,
               let url = navigationAction.request.url {
                if let scheme = url.scheme?.lowercased(),
                   scheme != "http" && scheme != "https" {
                    UIApplication.shared.open(url)
                } else {
                    webView.load(navigationAction.request)
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if #available(iOS 14.5, *),
               let http = navigationResponse.response as? HTTPURLResponse {
                let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
                if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
                    decisionHandler(.download)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            persistCurrentCookies()

            // Se il processo WebKit viene terminato proprio mentre è aperto un
            // pannello iOS (File/Condividi), non ricarichiamo sotto al pannello.
            // Aspettiamo che l'app torni attiva.
            if isAppActive && UIApplication.shared.applicationState == .active {
                if webView.url != nil {
                    webView.reload()
                } else {
                    loadStartPage()
                }
            } else {
                webContentProcessNeedsReload = true
            }
        }

        // MARK: - JavaScript dialogs

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            guard let presenter = topViewController(for: webView) else {
                completionHandler()
                return
            }

            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler()
            })
            presenter.present(alert, animated: true)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            guard let presenter = topViewController(for: webView) else {
                completionHandler(false)
                return
            }

            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in
                completionHandler(false)
            })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(true)
            })
            presenter.present(alert, animated: true)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            guard let presenter = topViewController(for: webView) else {
                completionHandler(nil)
                return
            }

            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { textField in
                textField.text = defaultText
            }
            alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in
                completionHandler(nil)
            })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }

        private func topViewController(for webView: WKWebView) -> UIViewController? {
            var controller = webView.window?.rootViewController

            while true {
                if let presented = controller?.presentedViewController {
                    controller = presented
                } else if let navigation = controller as? UINavigationController {
                    controller = navigation.visibleViewController
                } else if let tab = controller as? UITabBarController {
                    controller = tab.selectedViewController
                } else {
                    break
                }
            }

            return controller
        }
    }
}
