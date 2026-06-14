internal enum Log {
    static let app = DualLogger(subsystem: "cam.lemur", category: "app")
    static let ipc = DualLogger(subsystem: "cam.lemur", category: "ipc")
    static let rtsp = DualLogger(subsystem: "cam.lemur", category: "rtsp")
}
