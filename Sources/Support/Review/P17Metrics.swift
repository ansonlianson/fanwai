import Foundation

/// Opt-in local development measurements. No URLs, queries, account information,
/// credentials or model traffic are recorded. Ordinary launches do no work.
actor P17Metrics {
    static let shared=P17Metrics()
    nonisolated static var enabled:Bool {
        ProcessInfo.processInfo.arguments.contains("--p17-measure")
    }
    private var rows:[[String:String]]=[]
    private var flushing=false
    func request(host:String,queued:Date,started:Date,status:String) {
        guard Self.enabled else { return }
        rows.append(["event":"request","host":host,"queued":String(queued.timeIntervalSince1970),"started":String(started.timeIntervalSince1970),"ended":String(Date().timeIntervalSince1970),"waitMs":String(started.timeIntervalSince(queued)*1000),"status":status])
        schedule()
    }
    func event(_ name:String,entity:String,count:Int=0) {
        guard Self.enabled else { return }
        rows.append(["event":name,"entity":entity,"count":String(count),"time":String(Date().timeIntervalSince1970)])
        schedule()
    }
    func record(_ row: [String: String]) {
        guard Self.enabled else { return }
        rows.append(row.merging(["time": String(Date().timeIntervalSince1970)]) { a, _ in a })
        schedule()
    }
    private func schedule() {
        guard !flushing else { return }; flushing=true
        Task { try? await Task.sleep(for:.seconds(1)); flush() }
    }
    private func flush() {
        flushing=false
        guard let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        if let data=try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) {
            var file = directory.appendingPathComponent("P17-metrics.json")
            #if targetEnvironment(simulator)
            if let output = ProcessInfo.processInfo.environment["PIANWAI_EVAL_IMAGE_OUTPUT"], output.contains("/Design/review/EVAL-0.5.15/") { file = URL(fileURLWithPath: output) }
            #endif
            try? data.write(to:file,options:.atomic)
        }
    }
}
