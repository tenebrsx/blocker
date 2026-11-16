import Foundation

/// Keeps large, open adult-site blocklists on the Mac and answers "is this host on one?".
///
/// The lists are downloaded by the app itself (nothing is bundled or hand-maintained), cached in
/// `~/Library/Application Support/WordBlocker/`, and refreshed in the background. Until the first download
/// finishes, or when offline, the built-in list in `AdultSiteMatcher` still applies. Only a plain HTTPS GET
/// is made to each list's host; nothing about you is sent.
public final class AdultDomainList {
    public static let shared = AdultDomainList()

    struct Source {
        let name: String
        let url: URL
        /// Re-download once the cached copy is older than this many days.
        let refreshDays: Double
    }

    /// StevenBlack's porn-only list (~77k domains, actively maintained, MIT) and the Blocklist Project's
    /// porn list (~1M domains, Unlicense; the project is archived, so it is refreshed rarely).
    static let sources: [Source] = [
        Source(name: "stevenblack-porn",
               url: URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-only/hosts")!,
               refreshDays: 7),
        Source(name: "blocklistproject-porn",
               url: URL(string: "https://blocklistproject.github.io/Lists/alt-version/porn-nl.txt")!,
               refreshDays: 60)
    ]

    /// A download with fewer domains than this is treated as broken (an error page, a truncated file)
    /// and the previous copy is kept.
    static let minimumPlausibleDomains = 1_000

    private let lock = NSLock()
    private var indexes: [String: AdultDomainIndex] = [:]
    private var retryAfter: [String: Date] = [:]
    private var started = false
    private var refreshTimer: Timer?
    private let queue = DispatchQueue(label: "com.wordblocker.adultlist", qos: .utility)

    /// Called on the main thread whenever a list finishes loading.
    public var onChange: (() -> Void)?

    private init() {}

    // MARK: - Public

    /// Loads cached lists, downloads missing or stale ones, and keeps them fresh. Safe to call repeatedly.
    public func start() {
        guard !started else { return }
        started = true

        AdultSiteMatcher.domainLookup = { [weak self] host in self?.contains(host: host) ?? false }

        queue.async { [weak self] in
            self?.loadCachedLists()
            self?.refreshStaleLists()
        }

        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            self?.queue.async { self?.refreshStaleLists() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    public func contains(host: String) -> Bool {
        lock.lock()
        let current = Array(indexes.values)
        lock.unlock()
        for index in current where index.containsHost(host) { return true }
        return false
    }

    public var totalDomains: Int {
        lock.lock()
        defer { lock.unlock() }
        return indexes.values.reduce(0) { $0 + $1.count }
    }

    /// One line for the menu: how many domains are loaded.
    public var statusText: String {
        let total = totalDomains
        if total == 0 { return "Adult blocklist: downloading…" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let text = formatter.string(from: NSNumber(value: total)) ?? "\(total)"
        return "Adult blocklist: \(text) domains"
    }

    // MARK: - Cache

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WordBlocker", isDirectory: true)
    }

    private func cacheURL(for source: Source) -> URL {
        cacheDirectory.appendingPathComponent("adult-\(source.name).bin")
    }

    private func loadCachedLists() {
        for source in AdultDomainList.sources {
            guard let data = try? Data(contentsOf: cacheURL(for: source)), data.count >= 8 else { continue }
            let index = AdultDomainIndex(serialized: [UInt8](data))
            guard index.count >= AdultDomainList.minimumPlausibleDomains else { continue }
            install(index, for: source)
        }
    }

    private func isStale(_ source: Source) -> Bool {
        let path = cacheURL(for: source).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) > source.refreshDays * 86_400
    }

    private func install(_ index: AdultDomainIndex, for source: Source) {
        lock.lock()
        indexes[source.name] = index
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    // MARK: - Download

    private func refreshStaleLists() {
        let due = AdultDomainList.sources.filter { source in
            guard isStale(source) else { return false }
            lock.lock()
            let wait = retryAfter[source.name] ?? .distantPast
            lock.unlock()
            return Date() >= wait
        }
        refresh(due[...])
    }

    /// Downloads one list at a time, so memory use stays bounded.
    private func refresh(_ remaining: ArraySlice<Source>) {
        guard let source = remaining.first else { return }
        let rest = remaining.dropFirst()

        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("WordBlocker-list-updater", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)

        let task = session.downloadTask(with: request) { [weak self] location, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let self = self else { return }

            var bytes: [UInt8]?
            if error == nil,
               (response as? HTTPURLResponse)?.statusCode == 200,
               let location = location,
               let data = try? Data(contentsOf: location) {
                bytes = [UInt8](data)   // read now: the temporary file is deleted when this handler returns
            }

            self.queue.async {
                self.finishDownload(source: source, bytes: bytes)
                self.refresh(rest)
            }
        }
        task.resume()
    }

    private func finishDownload(source: Source, bytes: [UInt8]?) {
        guard let bytes = bytes else { return retryLater(source) }

        let index = AdultDomainIndex(hashes: AdultDomainIndex.parse(bytes))
        guard index.count >= AdultDomainList.minimumPlausibleDomains else { return retryLater(source) }

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try Data(index.serialized()).write(to: cacheURL(for: source), options: .atomic)
        } catch {
            print("[AdultDomainList] Could not save \(source.name): \(error)")
        }
        install(index, for: source)
        print("[AdultDomainList] \(source.name): \(index.count) domains")
    }

    /// A failed or implausible download (offline, rate limited, an error page) is retried in 30 minutes.
    private func retryLater(_ source: Source) {
        lock.lock()
        retryAfter[source.name] = Date().addingTimeInterval(1_800)
        lock.unlock()
        print("[AdultDomainList] Download of \(source.name) failed; will retry later")
    }
}
