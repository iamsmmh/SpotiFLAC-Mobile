import AuthenticationServices
import Flutter
import UIKit
import UniformTypeIdentifiers
import Gobackend

@main
@objc class AppDelegate: FlutterAppDelegate {
    private let CHANNEL = "com.zarz.spotiflac/backend"
    private let DOWNLOAD_PROGRESS_STREAM_CHANNEL = "com.zarz.spotiflac/download_progress_stream"
    private let LIBRARY_SCAN_PROGRESS_STREAM_CHANNEL = "com.zarz.spotiflac/library_scan_progress_stream"
    private let LARGE_JSON_RESULT_FILE_KEY = "__json_file"
    private let LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES = 256 * 1024
    private let streamQueue = DispatchQueue(label: "com.zarz.spotiflac.progress_stream", qos: .utility)
    private var downloadProgressTimer: DispatchSourceTimer?
    private var downloadProgressEventSink: FlutterEventSink?
    private var lastDownloadProgressPayload: String?
    private var lastDownloadProgressSeq: Int64 = 0
    private var libraryScanProgressTimer: DispatchSourceTimer?
    private var libraryScanProgressEventSink: FlutterEventSink?
    private var lastLibraryScanProgressPayload: String?
    private var backendChannel: FlutterMethodChannel?
    private var pendingSessionGrantEvents: [[String: Any]] = []
    
    private let securityScopedAccessLock = NSLock()
    private var securityScopedAccesses: [String: URL] = [:]

    /// Pending Flutter result for the native folder picker
    private var pendingDirectoryPickerResult: FlutterResult?

    /// Whether a download queue is active; while true a background task is
    /// started on each background entry to extend execution time. Main-thread only.
    private var downloadsActive = false
    private var downloadBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Strong reference to the in-flight ASWebAuthenticationSession; the
    /// session is deallocated (and its sheet dismissed) without it.
    private var activeWebAuthSession: AnyObject?
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            GobackendSetAppVersion(version)
        }
        
        let controller = window?.rootViewController as! FlutterViewController
        let channel = FlutterMethodChannel(
            name: CHANNEL,
            binaryMessenger: controller.binaryMessenger
        )
        backendChannel = channel
        if !pendingSessionGrantEvents.isEmpty {
            let events = pendingSessionGrantEvents
            pendingSessionGrantEvents.removeAll()
            for event in events {
                channel.invokeMethod("extensionSessionGrantCompleted", arguments: event)
            }
        }
        let downloadProgressEvents = FlutterEventChannel(
            name: DOWNLOAD_PROGRESS_STREAM_CHANNEL,
            binaryMessenger: controller.binaryMessenger
        )
        let libraryScanProgressEvents = FlutterEventChannel(
            name: LIBRARY_SCAN_PROGRESS_STREAM_CHANNEL,
            binaryMessenger: controller.binaryMessenger
        )
        
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call: call, result: result)
        }
        downloadProgressEvents.setStreamHandler(
            ClosureStreamHandler(
                onListen: { [weak self] _, events in
                    self?.startDownloadProgressStream(events)
                    return nil
                },
                onCancel: { [weak self] _ in
                    self?.stopDownloadProgressStream()
                    return nil
                }
            )
        )
        libraryScanProgressEvents.setStreamHandler(
            ClosureStreamHandler(
                onListen: { [weak self] _, events in
                    self?.startLibraryScanProgressStream(events)
                    return nil
                },
                onCancel: { [weak self] _ in
                    self?.stopLibraryScanProgressStream()
                    return nil
                }
            )
        )
        
        GeneratedPluginRegistrant.register(with: self)
        if let url = launchOptions?[.url] as? URL {
            _ = handleExtensionOAuthRedirect(url: url)
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    /// Extension return URLs:
    /// - OAuth: spotiflac://callback?code=...&state=<extension_id>
    /// - Signed session: spotiflac://session-grant?grant=...&state=<extension_id>
    @discardableResult
    private func handleExtensionOAuthRedirect(url: URL) -> Bool {
        guard let route = ExtensionCallbackParser.parse(url) else { return false }
        streamQueue.async {
            var err: NSError?
            var response: String?
            // gomobile binds Go functions that return an `error` as throwing
            // Swift functions, so the failure surfaces through `catch` rather
            // than an out-parameter.
            do {
                if route.isSessionGrant {
                    GobackendSetExtensionSessionGrantByID(route.extensionId, route.code)
                    response = try GobackendInvokeExtensionActionJSON(
                        route.extensionId,
                        "completeGrant"
                    )
                } else {
                    GobackendSetExtensionAuthCodeByID(route.extensionId, route.code)
                    response = try GobackendInvokeExtensionActionJSON(
                        route.extensionId,
                        "completeSpotifyLogin"
                    )
                }
            } catch {
                err = error as NSError
            }
            if err == nil && route.isSessionGrant {
                do {
                    try self.requireSuccessfulExtensionAction(
                        extensionId: route.extensionId,
                        actionName: "completeGrant",
                        response: response
                    )
                } catch {
                    err = error as NSError
                }
            }
            if let err = err {
                NSLog(
                    "SpotiFLAC: Extension callback complete failed: \(err.localizedDescription)")
            } else if route.isSessionGrant {
                DispatchQueue.main.async { [weak self] in
                    self?.notifySessionGrantCompleted(
                        extensionId: route.extensionId
                    )
                }
            }
        }
        return true
    }

    private func requireSuccessfulExtensionAction(
        extensionId: String,
        actionName: String,
        response: String?
    ) throws {
        let text = response ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "SpotiFLAC",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Extension \(actionName) for \(extensionId) returned invalid JSON: \(String(text.prefix(240)))"
                ]
            )
        }
        if (obj["success"] as? Bool) == true {
            return
        }
        let error =
            (obj["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            String(text.prefix(240))
        throw NSError(
            domain: "SpotiFLAC",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "Extension \(actionName) failed for \(extensionId): \(error)"
            ]
        )
    }

    private func notifySessionGrantCompleted(extensionId: String) {
        let payload: [String: Any] = [
            "extension_id": extensionId,
            "success": true,
        ]
        if let channel = backendChannel {
            channel.invokeMethod("extensionSessionGrantCompleted", arguments: payload)
        } else {
            pendingSessionGrantEvents.append(payload)
        }
    }

    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        if handleExtensionOAuthRedirect(url: url) {
            return true
        }
        return super.application(app, open: url, options: options)
    }

    deinit {
        stopDownloadProgressStream()
        stopLibraryScanProgressStream()
    }

    private func startDownloadProgressStream(_ eventSink: @escaping FlutterEventSink) {
        stopDownloadProgressStream()
        downloadProgressEventSink = eventSink
        lastDownloadProgressPayload = nil
        lastDownloadProgressSeq = 0

        let timer = DispatchSource.makeTimerSource(queue: streamQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(800))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let payload = GobackendGetAllDownloadProgressDelta(self.lastDownloadProgressSeq) as String? ?? ""
            if payload.isEmpty || payload == self.lastDownloadProgressPayload {
                return
            }
            self.updateDownloadProgressSeq(payload)
            self.lastDownloadProgressPayload = payload
            DispatchQueue.main.async { [weak self] in
                self?.downloadProgressEventSink?(self?.parseJsonPayload(payload))
            }
        }
        downloadProgressTimer = timer
        timer.resume()
    }

    private func stopDownloadProgressStream() {
        downloadProgressTimer?.setEventHandler {}
        downloadProgressTimer?.cancel()
        downloadProgressTimer = nil
        downloadProgressEventSink = nil
        lastDownloadProgressPayload = nil
        lastDownloadProgressSeq = 0
    }

    private func startLibraryScanProgressStream(_ eventSink: @escaping FlutterEventSink) {
        stopLibraryScanProgressStream()
        libraryScanProgressEventSink = eventSink
        lastLibraryScanProgressPayload = nil

        let timer = DispatchSource.makeTimerSource(queue: streamQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(800))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let payload = GobackendGetLibraryScanProgressJSON() as String? ?? "{}"
            if payload == self.lastLibraryScanProgressPayload {
                return
            }
            self.lastLibraryScanProgressPayload = payload
            DispatchQueue.main.async { [weak self] in
                self?.libraryScanProgressEventSink?(self?.parseJsonPayload(payload))
            }
        }
        libraryScanProgressTimer = timer
        timer.resume()
    }

    private func stopLibraryScanProgressStream() {
        libraryScanProgressTimer?.setEventHandler {}
        libraryScanProgressTimer?.cancel()
        libraryScanProgressTimer = nil
        libraryScanProgressEventSink = nil
        lastLibraryScanProgressPayload = nil
    }

    private func parseJsonPayload(_ payload: String) -> Any {
        guard let data = payload.data(using: .utf8) else {
            return payload
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return payload
        }
    }

    private func updateDownloadProgressSeq(_ payload: String) {
        guard let data = payload.data(using: .utf8) else { return }
        do {
            if let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
               let seq = obj["seq"] as? NSNumber,
               seq.int64Value > lastDownloadProgressSeq {
                lastDownloadProgressSeq = seq.int64Value
            }
        } catch {
        }
    }

    private func bridgeJsonResult(_ payload: String) -> Any {
        if payload.utf8.count < LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES {
            return payload
        }

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bridge_json_\(UUID().uuidString).json")
            try payload.write(to: url, atomically: true, encoding: .utf8)
            return [LARGE_JSON_RESULT_FILE_KEY: url.path]
        } catch {
            NSLog("SpotiFLAC: failed to spill large bridge JSON result to file: \(error.localizedDescription)")
            return payload
        }
    }
    
    private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "beginBackgroundDownloadTask":
            downloadsActive = true
            result(nil)
            return
        case "endBackgroundDownloadTask":
            downloadsActive = false
            endBackgroundDownloadTask()
            result(nil)
            return
        case "pickIosDirectory":
            pickIosDirectory(result: result)
            return
        case "startWebAuthSession":
            let args = call.arguments as? [String: Any] ?? [:]
            let urlString = (args["url"] as? String) ?? ""
            let callbackScheme = (args["callback_scheme"] as? String) ?? "spotiflac"
            startWebAuthSession(
                urlString: urlString,
                callbackScheme: callbackScheme,
                result: result
            )
            return
        default:
            break
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try self.invokeGoMethod(call: call)
                DispatchQueue.main.async {
                    result(response)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    /// Runs a verification/OAuth page inside ASWebAuthenticationSession. The
    /// session intercepts the callback scheme in-process — no OS-level URL
    /// scheme registration is involved — so the flow completes even where the
    /// app's scheme is not registered with iOS (sideload containers such as
    /// LiveContainer). The callback URL is fed into the same deep-link handler
    /// the OS path uses. Returns whether the session was presented; completion
    /// is delivered later through the existing grant-event plumbing.
    private func startWebAuthSession(
        urlString: String,
        callbackScheme: String,
        result: @escaping FlutterResult
    ) {
        guard #available(iOS 13.0, *) else {
            result(false)
            return
        }
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            result(false)
            return
        }
        let scheme = callbackScheme.isEmpty ? "spotiflac" : callbackScheme
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: scheme
        ) { [weak self] callbackURL, error in
            self?.activeWebAuthSession = nil
            guard let callbackURL = callbackURL else {
                if let error = error {
                    NSLog("SpotiFLAC: web auth session ended: \(error.localizedDescription)")
                }
                return
            }
            _ = self?.handleExtensionOAuthRedirect(url: callbackURL)
        }
        session.presentationContextProvider = self
        // Share Safari's cookie store so captcha providers see an established
        // browsing context instead of a blank ephemeral one.
        session.prefersEphemeralWebBrowserSession = false
        activeWebAuthSession = session
        let started = session.start()
        if !started {
            activeWebAuthSession = nil
        }
        result(started)
    }

    override func applicationDidEnterBackground(_ application: UIApplication) {
        super.applicationDidEnterBackground(application)
        if downloadsActive {
            beginBackgroundDownloadTask()
        }
    }

    override func applicationWillEnterForeground(_ application: UIApplication) {
        super.applicationWillEnterForeground(application)
        endBackgroundDownloadTask()
    }

    private func beginBackgroundDownloadTask() {
        if downloadBackgroundTask != .invalid { return }
        downloadBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "SpotiFLACDownloads"
        ) { [weak self] in
            self?.endBackgroundDownloadTask()
        }
    }

    private func endBackgroundDownloadTask() {
        if downloadBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(downloadBackgroundTask)
            downloadBackgroundTask = .invalid
        }
    }
    
    private func invokeGoMethod(call: FlutterMethodCall) throws -> Any? {
        switch call.method {
        case "downloadByStrategy":
            let requestJson = call.arguments as! String
            let response: String? = try GobackendDownloadByStrategy(requestJson)
            return response

        case "getAllDownloadProgress":
            let response = GobackendGetAllDownloadProgress()
            return parseJsonPayload(response as String? ?? "{}")
            
        case "clearItemProgress":
            let args = call.arguments as! [String: Any]
            let itemId = args["item_id"] as! String
            GobackendClearItemProgress(itemId)
            return nil

        case "cancelDownload":
            let args = call.arguments as! [String: Any]
            let itemId = args["item_id"] as! String
            GobackendCancelDownload(itemId)
            return nil

        case "resetDownloadCancel":
            let args = call.arguments as! [String: Any]
            let itemId = args["item_id"] as! String
            GobackendResetDownloadCancel(itemId)
            return nil

        case "setDownloadDirectory":
            let args = call.arguments as! [String: Any]
            let path = args["path"] as! String
            try GobackendSetDownloadDirectory(path)
            return nil

        case "setNetworkCompatibilityOptions", "setSongLinkNetworkOptions":
            let args = call.arguments as! [String: Any]
            let allowHTTP = args["allow_http"] as? Bool ?? false
            let insecureTLS = args["insecure_tls"] as? Bool ?? false
            GobackendSetNetworkCompatibilityOptions(allowHTTP, insecureTLS)
            return nil

        case "setAllowPrivateNetwork":
            let args = call.arguments as! [String: Any]
            let allowed = args["allowed"] as? Bool ?? false
            GobackendSetAllowPrivateNetwork(allowed)
            return nil
            
        case "checkDuplicatesBatch":
            let args = call.arguments as! [String: Any]
            let outputDir = args["output_dir"] as! String
            let tracksJson = args["tracks"] as? String ?? "[]"
            let response: String? = try GobackendCheckDuplicatesBatch(outputDir, tracksJson)
            return response
            
        case "preBuildDuplicateIndex":
            let args = call.arguments as! [String: Any]
            let outputDir = args["output_dir"] as! String
            try GobackendPreBuildDuplicateIndex(outputDir)
            return nil
            
        case "invalidateDuplicateIndex":
            let args = call.arguments as! [String: Any]
            let outputDir = args["output_dir"] as! String
            GobackendInvalidateDuplicateIndex(outputDir)
            return nil
            
        case "buildFilename":
            let args = call.arguments as! [String: Any]
            let template = args["template"] as! String
            let metadata = args["metadata"] as! String
            let response: String? = try GobackendBuildFilename(template, metadata)
            return response
            
        case "sanitizeFilename":
            let args = call.arguments as! [String: Any]
            let filename = args["filename"] as! String
            let response = GobackendSanitizeFilename(filename)
            return response
            
        case "getLyricsLRC":
            let args = call.arguments as! [String: Any]
            let spotifyId = args["spotify_id"] as! String
            let trackName = args["track_name"] as! String
            let artistName = args["artist_name"] as! String
            let filePath = args["file_path"] as? String ?? ""
            let durationMs = args["duration_ms"] as? Int64 ?? 0
            let response: String? = try GobackendGetLyricsLRC(spotifyId, trackName, artistName, filePath, durationMs)
            return response

        case "getLyricsLRCWithSource":
            let args = call.arguments as! [String: Any]
            let spotifyId = args["spotify_id"] as! String
            let trackName = args["track_name"] as! String
            let artistName = args["artist_name"] as! String
            let filePath = args["file_path"] as? String ?? ""
            let durationMs = args["duration_ms"] as? Int64 ?? 0
            let response: String? = try GobackendGetLyricsLRCWithSource(spotifyId, trackName, artistName, filePath, durationMs)
            return response
            
        case "embedLyricsToFile":
            let args = call.arguments as! [String: Any]
            let filePath = args["file_path"] as! String
            let lyrics = args["lyrics"] as! String
            let response: String? = try GobackendEmbedLyricsToFile(filePath, lyrics)
            return response
            
        case "rewriteSplitArtistTags":
            let args = call.arguments as! [String: Any]
            let filePath = args["file_path"] as! String
            let artist = args["artist"] as! String
            let albumArtist = args["album_artist"] as! String
            let response: String? = try GobackendRewriteSplitArtistTagsExport(filePath, artist, albumArtist)
            return response
            
        case "cleanupConnections":
            GobackendCleanupConnections()
            return nil

        case "downloadCoverToFile":
            let args = call.arguments as! [String: Any]
            let coverURL = args["cover_url"] as! String
            let outputPath = args["output_path"] as! String
            try GobackendDownloadCoverToFile(coverURL, outputPath, false)
            return "{\"success\":true}"

        case "extractCoverToFile":
            let args = call.arguments as! [String: Any]
            let audioPath = args["audio_path"] as! String
            let outputPath = args["output_path"] as! String
            try GobackendExtractCoverToFile(audioPath, outputPath)
            return "{\"success\":true}"

        case "fetchAndSaveLyrics":
            let args = call.arguments as! [String: Any]
            let trackName = args["track_name"] as! String
            let artistName = args["artist_name"] as! String
            let spotifyId = args["spotify_id"] as! String
            let durationMs = args["duration_ms"] as? Int64 ?? 0
            let outputPath = args["output_path"] as! String
            let audioFilePath = args["audio_file_path"] as? String ?? ""
            try GobackendFetchAndSaveLyrics(
                trackName,
                artistName,
                spotifyId,
                durationMs,
                outputPath,
                audioFilePath
            )
            return "{\"success\":true}"

        case "reEnrichFile":
            let args = call.arguments as! [String: Any]
            let requestJson = args["request_json"] as? String ?? "{}"
            let response: String? = try GobackendReEnrichFile(requestJson)
            return response
            
        case "readFileMetadata":
            let args = call.arguments as! [String: Any]
            let filePath = args["file_path"] as! String
            let response: String? = try GobackendReadFileMetadata(filePath)
            return response
            
        case "editFileMetadata":
            let args = call.arguments as! [String: Any]
            let filePath = args["file_path"] as! String
            let metadataJson = args["metadata_json"] as? String ?? "{}"
            let response: String? = try GobackendEditFileMetadata(filePath, metadataJson)
            return response
            
        case "getProviderMetadata":
            let args = call.arguments as! [String: Any]
            let providerId = args["provider_id"] as! String
            let resourceType = args["resource_type"] as! String
            let resourceId = args["resource_id"] as! String
            let response: String? = try GobackendGetProviderMetadataJSON(providerId, resourceType, resourceId)
            return response

        case "searchDeezerByISRC":
            let args = call.arguments as! [String: Any]
            let isrc = args["isrc"] as! String
            let itemId = args["item_id"] as? String ?? ""
            let response: String? = try GobackendSearchDeezerByISRCForItemID(isrc, itemId)
            return response

        case "getDeezerExtendedMetadata":
            let args = call.arguments as! [String: Any]
            let trackId = args["track_id"] as! String
            let response: String? = try GobackendGetDeezerExtendedMetadata(trackId)
            return response

        case "convertSpotifyToDeezer":
            let args = call.arguments as! [String: Any]
            let resourceType = args["resource_type"] as! String
            let spotifyId = args["spotify_id"] as! String
            let response: String? = try GobackendConvertSpotifyToDeezer(resourceType, spotifyId)
            return response

        case "getSpotifyIDFromDeezerTrack":
            let args = call.arguments as! [String: Any]
            let deezerTrackId = args["deezer_track_id"] as! String
            let response: String? = try GobackendGetSpotifyIDFromDeezerTrack(deezerTrackId)
            return response
            
        case "getTidalURLFromDeezerTrack":
            let args = call.arguments as! [String: Any]
            let deezerTrackId = args["deezer_track_id"] as! String
            let response: String? = try GobackendGetTidalURLFromDeezerTrack(deezerTrackId)
            return response
            
        case "getTrackCacheSize":
            let response = GobackendGetTrackCacheSize()
            return response
            
        case "clearTrackCache":
            GobackendClearTrackIDCache()
            return nil
            
        case "getLogsSince":
            let args = call.arguments as! [String: Any]
            let index = args["index"] as? Int ?? 0
            let response = GobackendGetLogsSince(Int(index))
            return response
            
        case "clearLogs":
            GobackendClearLogs()
            return nil

        case "releaseMemory":
            GobackendReleaseMemory()
            return nil

        case "releaseMemoryUnderPressure":
            GobackendReleaseMemoryUnderPressure()
            return nil

        case "getGoRuntimeMetrics":
            return GobackendGetRuntimeMetricsJSON()
            
        case "setLoggingEnabled":
            let args = call.arguments as! [String: Any]
            let enabled = args["enabled"] as? Bool ?? false
            GobackendSetLoggingEnabled(enabled)
            return nil
            
        case "initExtensionSystem":
            let args = call.arguments as! [String: Any]
            let extensionsDir = args["extensions_dir"] as! String
            let dataDir = args["data_dir"] as! String
            try GobackendInitExtensionSystem(extensionsDir, dataDir)
            return nil
            
        case "loadExtensionsFromDir":
            let args = call.arguments as! [String: Any]
            let dirPath = args["dir_path"] as! String
            let response: String? = try GobackendLoadExtensionsFromDir(dirPath)
            return response
            
        case "loadExtensionFromPath":
            let args = call.arguments as! [String: Any]
            let filePath = args["file_path"] as! String
            let response: String? = try GobackendLoadExtensionFromPath(filePath)
            return response
            
        case "unloadExtension":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            try GobackendUnloadExtensionByID(extensionId)
            return nil
            
        case "getInstalledExtensions":
            let response: String? = try GobackendGetInstalledExtensions()
            return response
            
        case "setExtensionEnabled":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let enabled = args["enabled"] as? Bool ?? false
            try GobackendSetExtensionEnabledByID(extensionId, enabled)
            return nil
            
        case "setProviderPriority":
            let args = call.arguments as! [String: Any]
            let priorityJson = args["priority"] as! String
            try GobackendSetProviderPriorityJSON(priorityJson)
            return nil
            
        case "getProviderPriority":
            let response: String? = try GobackendGetProviderPriorityJSON()
            return response

        case "setDownloadFallbackExtensionIds":
            let args = call.arguments as! [String: Any]
            let extensionIdsJson = args["extension_ids"] as? String ?? ""
            try GobackendSetExtensionFallbackProviderIDsJSON(extensionIdsJson)
            return nil
            
        case "setMetadataProviderPriority":
            let args = call.arguments as! [String: Any]
            let priorityJson = args["priority"] as! String
            try GobackendSetMetadataProviderPriorityJSON(priorityJson)
            return nil
            
        case "getMetadataProviderPriority":
            let response: String? = try GobackendGetMetadataProviderPriorityJSON()
            return response
            
        case "getExtensionSettings":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let response: String? = try GobackendGetExtensionSettingsJSON(extensionId)
            return response

        case "checkExtensionHealth":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let response: String? = try GobackendCheckExtensionHealthJSON(extensionId)
            return response
            
        case "setExtensionSettings":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let settingsJson = args["settings"] as! String
            try GobackendSetExtensionSettingsJSON(extensionId, settingsJson)
            return nil
            
        case "invokeExtensionAction":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let actionName = args["action"] as! String
            let response: String? = try GobackendInvokeExtensionActionJSON(extensionId, actionName)
            return response
            
        case "searchTracksWithMetadataProviders":
            let args = call.arguments as! [String: Any]
            let query = args["query"] as! String
            let limit = args["limit"] as? Int ?? 20
            let includeExtensions = args["include_extensions"] as? Bool ?? true
            let response: String? = try GobackendSearchTracksWithMetadataProvidersJSON(query, Int(limit), includeExtensions)
            return response

        case "searchTracksWithMetadataProvider":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as? String ?? ""
            let query = args["query"] as? String ?? ""
            let limit = args["limit"] as? Int ?? 20
            let response: String? = try GobackendSearchTracksWithMetadataProviderJSON(extensionId, query, Int(limit))
            return response
            
        case "enrichTrackWithExtension":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let trackJson = args["track"] as? String ?? "{}"
            let response: String? = try GobackendEnrichTrackWithExtensionJSON(extensionId, trackJson)
            return response

        case "downloadWithExtensions":
            let requestJson = call.arguments as! String
            let response: String? = try GobackendDownloadWithExtensionsJSON(requestJson)
            return response
            
        case "removeExtension":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            try GobackendRemoveExtensionByID(extensionId)
            return nil
            
        case "upgradeExtension":
            let args = call.arguments as! [String: Any]
            let filePath = args["file_path"] as! String
            let response: String? = try GobackendUpgradeExtensionFromPath(filePath)
            return response
            
        case "checkExtensionUpgrade":
            let args = call.arguments as! [String: Any]
            let filePath = args["file_path"] as! String
            let response: String? = try GobackendCheckExtensionUpgradeFromPath(filePath)
            return response
            
        case "cleanupExtensions":
            GobackendCleanupExtensions()
            return nil
            
        case "getExtensionPendingAuth":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let response: String? = try GobackendGetExtensionPendingAuthJSON(extensionId)
            return response
            
        case "setExtensionAuthCode":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let authCode = args["auth_code"] as! String
            GobackendSetExtensionAuthCodeByID(extensionId, authCode)
            return nil

        case "completeExtensionSessionGrant":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let grant = args["grant"] as! String
            GobackendSetExtensionSessionGrantByID(extensionId, grant)
            let response: String? = try GobackendInvokeExtensionActionJSON(extensionId, "completeGrant")
            try requireSuccessfulExtensionAction(
                extensionId: extensionId,
                actionName: "completeGrant",
                response: response
            )
            return true
            
        case "setExtensionTokens":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let accessToken = args["access_token"] as! String
            let refreshToken = args["refresh_token"] as? String ?? ""
            let expiresIn = args["expires_in"] as? Int ?? 0
            GobackendSetExtensionTokensByID(extensionId, accessToken, refreshToken, Int(expiresIn))
            return nil
            
        case "clearExtensionPendingAuth":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            GobackendClearExtensionPendingAuthByID(extensionId)
            return nil
            
        case "isExtensionAuthenticated":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let response = GobackendIsExtensionAuthenticatedByID(extensionId)
            return response
            
        case "getAllPendingAuthRequests":
            let response: String? = try GobackendGetAllPendingAuthRequestsJSON()
            return response
            
        case "getPendingFFmpegCommand":
            let args = call.arguments as! [String: Any]
            let commandId = args["command_id"] as! String
            let response: String? = try GobackendGetPendingFFmpegCommandJSON(commandId)
            return response
            
        case "setFFmpegCommandResult":
            let args = call.arguments as! [String: Any]
            let commandId = args["command_id"] as! String
            let success = args["success"] as? Bool ?? false
            let output = args["output"] as? String ?? ""
            let errorMsg = args["error"] as? String ?? ""
            GobackendSetFFmpegCommandResult(commandId, success, output, errorMsg)
            return nil
            
        case "getAllPendingFFmpegCommands":
            let response: String? = try GobackendGetAllPendingFFmpegCommandsJSON()
            return response
            
        case "customSearchWithExtension":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let query = args["query"] as! String
            let optionsJson = args["options"] as? String ?? ""
            let requestId = args["request_id"] as? String ?? ""
            let response: String? = try GobackendCustomSearchWithExtensionJSONWithRequestID(
                extensionId,
                query,
                optionsJson,
                requestId
            )
            return response

        case "cancelExtensionRequest":
            let args = call.arguments as! [String: Any]
            let requestId = args["request_id"] as? String ?? ""
            GobackendCancelExtensionRequestJSON(requestId)
            return nil

        case "handleURLWithExtension":
            let args = call.arguments as! [String: Any]
            let url = args["url"] as! String
            let response: String? = try GobackendHandleURLWithExtensionJSON(url)
            return response
            
        case "findURLHandler":
            let args = call.arguments as! [String: Any]
            let url = args["url"] as! String
            let response = GobackendFindURLHandlerJSON(url)
            return response
            
        case "getTrackPlatformLinks":
            let args = call.arguments as! [String: Any]
            let spotifyId = args["spotify_id"] as? String ?? ""
            let isrc = args["isrc"] as? String ?? ""
            let response: String? = try GobackendGetTrackPlatformLinksJSON(spotifyId, isrc)
            return response

        case "fetchMusicBrainzTags":
            let args = call.arguments as! [String: Any]
            let isrc = args["isrc"] as? String ?? ""
            let albumName = args["album_name"] as? String ?? ""
            let genre = (try? GobackendFetchMusicBrainzGenreByISRC(isrc)) ?? ""
            let albumArtist = (try? GobackendFetchMusicBrainzAlbumArtistByISRC(isrc, albumName)) ?? ""
            let payload: [String: Any] = [
                "genre": genre,
                "album_artist": albumArtist,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return String(data: data, encoding: .utf8) ?? "{}"
            
        case "runPostProcessingV2":
            let args = call.arguments as! [String: Any]
            let inputJson = args["input"] as? String ?? ""
            let metadataJson = args["metadata"] as? String ?? ""
            let response: String? = try GobackendRunPostProcessingV2JSON(inputJson, metadataJson)
            return response
            
        case "initExtensionRepo":
            let args = call.arguments as! [String: Any]
            let cacheDir = args["cache_dir"] as! String
            try GobackendInitExtensionRepoJSON(cacheDir)
            return nil
            
        case "setRepoRegistryUrl":
            let args = call.arguments as! [String: Any]
            let registryUrl = args["registry_url"] as? String ?? ""
            try GobackendSetRepoRegistryURLJSON(registryUrl)
            return nil
            
        case "getRepoRegistryUrl":
            let response: String? = try GobackendGetRepoRegistryURLJSON()
            return response
            
        case "clearRepoRegistryUrl":
            try GobackendClearRepoRegistryURLJSON()
            return nil
            
        case "getRepoExtensions":
            let args = call.arguments as! [String: Any]
            let forceRefresh = args["force_refresh"] as? Bool ?? false
            let response: String? = try GobackendGetRepoExtensionsJSON(forceRefresh)
            return response
            
        case "searchRepoExtensions":
            let args = call.arguments as! [String: Any]
            let query = args["query"] as? String ?? ""
            let category = args["category"] as? String ?? ""
            let response: String? = try GobackendSearchRepoExtensionsJSON(query, category)
            return response
            
        case "getRepoCategories":
            let response: String? = try GobackendGetRepoCategoriesJSON()
            return response
            
        case "downloadRepoExtension":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let destDir = args["dest_dir"] as! String
            let response: String? = try GobackendDownloadRepoExtensionJSON(extensionId, destDir)
            return response
            
        case "clearRepoCache":
            try GobackendClearRepoCacheJSON()
            return nil
            
        case "getExtensionHomeFeed":
            let args = call.arguments as! [String: Any]
            let extensionId = args["extension_id"] as! String
            let requestId = args["request_id"] as? String ?? ""
            let response: String? = try GobackendGetExtensionHomeFeedJSONWithRequestID(extensionId, requestId)
            return response
            
        case "setLibraryCoverCacheDir":
            let args = call.arguments as! [String: Any]
            let cacheDir = args["cache_dir"] as! String
            GobackendSetLibraryCoverCacheDirJSON(cacheDir)
            return nil
            
        case "scanLibraryFolder":
            let args = call.arguments as! [String: Any]
            let folderPath = args["folder_path"] as! String
            let response: String? = try GobackendScanLibraryFolderJSON(folderPath)
            return bridgeJsonResult(response as String? ?? "[]")

        case "scanLibraryFolderToNDJSONFile":
            guard
                let args = call.arguments as? [String: Any],
                let folderPath = args["folder_path"] as? String,
                !folderPath.isEmpty,
                let outputPath = args["output_path"] as? String,
                !outputPath.isEmpty
            else {
                throw invalidArgumentsError(call.method)
            }
            var count = 0
            // `(int, error)` in Go binds to a throwing Swift function whose
            // non-nullable first result comes back through an out-pointer.
            let succeeded = try withUnsafeMutablePointer(to: &count) {
                try GobackendScanLibraryFolderToNDJSONFileJSON(folderPath, outputPath, $0)
            }
            if !succeeded {
                throw NSError(
                    domain: "SpotiFLAC",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Library scan failed"]
                )
            }
            return ["path": outputPath, "count": count]
            
        case "scanLibraryFolderIncremental":
            let args = call.arguments as! [String: Any]
            let folderPath = args["folder_path"] as! String
            let existingFiles = args["existing_files"] as? String ?? "{}"
            let response: String? = try GobackendScanLibraryFolderIncrementalJSON(folderPath, existingFiles)
            return bridgeJsonResult(response as String? ?? "{}")
            
        case "getLibraryScanProgress":
            let response = GobackendGetLibraryScanProgressJSON()
            return parseJsonPayload(response as String? ?? "{}")
            
        case "cancelLibraryScan":
            GobackendCancelLibraryScanJSON()
            return nil
            
        case "readAudioMetadata":
            let args = call.arguments as! [String: Any]
            let filePath = args["file_path"] as! String
            let response: String? = try GobackendReadAudioMetadataJSON(filePath)
            return response
        
        case "resolveIosBookmark":
            let args = call.arguments as! [String: Any]
            let bookmarkBase64 = args["bookmark"] as! String
            return try resolveIosBookmark(bookmarkBase64)
            
        case "startAccessingIosBookmark":
            guard
                let args = call.arguments as? [String: Any],
                let bookmarkBase64 = args["bookmark"] as? String,
                !bookmarkBase64.isEmpty
            else {
                throw invalidArgumentsError(call.method)
            }
            return try startAccessingIosBookmark(bookmarkBase64)
            
        case "stopAccessingIosBookmark":
            guard
                let args = call.arguments as? [String: Any],
                let token = args["token"] as? String,
                !token.isEmpty
            else {
                throw invalidArgumentsError(call.method)
            }
            stopAccessingIosBookmark(token: token)
            return nil
            
        case "createIosBookmarkFromPath":
            let args = call.arguments as! [String: Any]
            let path = args["path"] as! String
            return try createIosBookmarkFromPath(path)
            
        case "setLyricsProviders":
            let args = call.arguments as! [String: Any]
            let providersJson = args["providers_json"] as? String ?? "[]"
            try GobackendSetLyricsProvidersJSON(providersJson)
            return "{\"success\":true}"
            
        case "getLyricsProviders":
            let response: String? = try GobackendGetLyricsProvidersJSON()
            return response
            
        case "getAvailableLyricsProviders":
            let response: String? = try GobackendGetAvailableLyricsProvidersJSON()
            return response
            
        case "setLyricsFetchOptions":
            let args = call.arguments as! [String: Any]
            let optionsJson = args["options_json"] as? String ?? "{}"
            try GobackendSetLyricsFetchOptionsJSON(optionsJson)
            return "{\"success\":true}"
            
        case "getLyricsFetchOptions":
            let response: String? = try GobackendGetLyricsFetchOptionsJSON()
            return response
            
        case "parseCueSheet":
            let args = call.arguments as! [String: Any]
            let cuePath = args["cue_path"] as! String
            let audioDir = args["audio_dir"] as? String ?? ""
            let response: String? = try GobackendParseCueSheet(cuePath, audioDir)
            return response
            
        default:
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Method not implemented: \(call.method)"]
            )
        }
    }
    
    // MARK: - Native Folder Picker

    /// Present a native folder picker and return `{path, bookmark}` where the
    /// security-scoped bookmark is created inside the picker callback, while
    /// the picker's access grant is still active. Returns nil on cancel.
    private func pickIosDirectory(result: @escaping FlutterResult) {
        if pendingDirectoryPickerResult != nil {
            result(FlutterError(
                code: "PICKER_ACTIVE",
                message: "A folder picker is already active",
                details: nil
            ))
            return
        }
        guard var topController = window?.rootViewController else {
            result(FlutterError(
                code: "NO_VIEW_CONTROLLER",
                message: "No view controller available to present the folder picker",
                details: nil
            ))
            return
        }
        while let presented = topController.presentedViewController {
            topController = presented
        }
        pendingDirectoryPickerResult = result
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        topController.present(picker, animated: true)
    }

    // MARK: - iOS Security-Scoped Bookmark Helpers

    /// Create a security-scoped bookmark from a filesystem path (e.g. from FilePicker).
    /// The path must currently be accessible (within the same picker session).
    /// Returns base64-encoded bookmark data.
    private func createIosBookmarkFromPath(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        do {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = .withSecurityScope
            #else
            let options: URL.BookmarkCreationOptions = []
            #endif
            let bookmarkData = try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return bookmarkData.base64EncodedString()
        } catch {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create bookmark for path \(path): \(error.localizedDescription)"]
            )
        }
    }
    
    /// Resolve a base64-encoded security-scoped bookmark and return the resolved path.
    /// Does NOT start accessing the resource.
    private func resolveIosBookmark(_ bookmarkBase64: String) throws -> String {
        guard let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid base64 bookmark data"]
            )
        }
        
        var isStale = false
        let url: URL
        do {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve bookmark: \(error.localizedDescription)"]
            )
        }
        
        return url.path
    }
    
    private func invalidArgumentsError(_ method: String) -> NSError {
        return NSError(
            domain: "SpotiFLAC",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid arguments for \(method)"]
        )
    }

    /// Starts an independently owned security-scoped lease.
    private func startAccessingIosBookmark(_ bookmarkBase64: String) throws -> [String: String] {
        guard let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid base64 bookmark data"]
            )
        }
        
        var isStale = false
        let url: URL
        do {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve bookmark: \(error.localizedDescription)"]
            )
        }
        
        guard url.startAccessingSecurityScopedResource() else {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start accessing security-scoped resource at \(url.path)"]
            )
        }
        
        let token = UUID().uuidString
        securityScopedAccessLock.lock()
        securityScopedAccesses[token] = url
        securityScopedAccessLock.unlock()
        return ["path": url.path, "token": token]
    }
    
    /// Releases only the lease identified by the caller's token.
    private func stopAccessingIosBookmark(token: String) {
        securityScopedAccessLock.lock()
        let url = securityScopedAccesses.removeValue(forKey: token)
        securityScopedAccessLock.unlock()
        url?.stopAccessingSecurityScopedResource()
    }
}

@available(iOS 13.0, *)
extension AppDelegate: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return window ?? ASPresentationAnchor()
    }
}

extension AppDelegate: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let result = pendingDirectoryPickerResult else { return }
        pendingDirectoryPickerResult = nil
        guard let url = urls.first else {
            result(nil)
            return
        }
        // The bookmark must be created here, from the picker's own URL, while
        // its security-scoped grant is active. A URL rebuilt from the path
        // string later has no grant, so bookmark creation either fails or
        // yields a bookmark that cannot re-open the folder.
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            result([
                "path": url.path,
                "bookmark": bookmarkData.base64EncodedString(),
            ])
        } catch {
            result(FlutterError(
                code: "BOOKMARK_FAILED",
                message: "Failed to create bookmark for \(url.path): \(error.localizedDescription)",
                details: nil
            ))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingDirectoryPickerResult?(nil)
        pendingDirectoryPickerResult = nil
    }
}

private final class ClosureStreamHandler: NSObject, FlutterStreamHandler {
    typealias ListenHandler = (_ arguments: Any?, _ events: @escaping FlutterEventSink) -> FlutterError?
    typealias CancelHandler = (_ arguments: Any?) -> FlutterError?

    private let onListenHandler: ListenHandler
    private let onCancelHandler: CancelHandler

    init(
        onListen: @escaping ListenHandler,
        onCancel: @escaping CancelHandler = { _ in nil }
    ) {
        self.onListenHandler = onListen
        self.onCancelHandler = onCancel
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListenHandler(arguments, events)
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onCancelHandler(arguments)
    }
}
