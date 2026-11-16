import Foundation
import Darwin
import ServerCore
import SenseNovaU1

@main struct Main {
    static func main() async {
        setbuf(stdout, nil)
        do {
            let config = try Configuration()
            let key = try Auth.loadKey(path: config.keyFile)
            let jobs = JobQueue()
            let tokenizer = try await SenseNovaTokenizer.load(from: URL(fileURLWithPath: config.weights))
            let engine = Engine(config: config, jobs: jobs, tokenizer: tokenizer)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                jobs.worker.async { do { try engine.load(); continuation.resume() } catch { continuation.resume(throwing: error) } }
            }
            let server = try HTTPServer(config: config, key: key, jobs: jobs, engine: engine)
            server.start()
            let timer = DispatchSource.makeTimerSource(queue: jobs.worker)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { engine.unloadIfIdle() }; timer.resume()
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
            let signals = [SIGTERM, SIGINT].map { code -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: code, queue: .global())
                source.setEventHandler {
                    print("Shutting down; draining accepted GPU jobs")
                    server.stop()
                    jobs.drain { server.waitForResponsesAndExit() }
                }
                source.resume(); return source
            }
            while true {
                try await Task.sleep(for: .seconds(3600))
                withExtendedLifetime((server, timer, signals)) {}
            }
        } catch { fputs("Startup failed: \(error)\n", stderr); exit(1) }
    }
}
