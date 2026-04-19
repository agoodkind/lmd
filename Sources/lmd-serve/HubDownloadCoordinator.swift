import AppLogger
import Foundation
import HuggingFace
import SwiftLMCore
import SwiftLMControl

private let log = AppLogger.logger(category: "HubDownload")
private let signposter = AppLogger.signposter(category: "Performance")

enum HubDownloadError: Error, CustomStringConvertible {
  case malformedSlug(String)

  var description: String {
    switch self {
    case .malformedSlug(let slug):
      return "slug must be <namespace>/<name>, got \(slug)"
    }
  }
}

actor HubDownloadCoordinator {
  nonisolated func start(slug: String) -> AsyncThrowingStream<PullEvent, Error> {
    AsyncThrowingStream { continuation in
      Task.detached {
        let intervalState = signposter.beginInterval(
          "hub.download",
          id: signposter.makeSignpostID(),
          "slug=\(slug, privacy: .public)"
        )
        defer { signposter.endInterval("hub.download", intervalState) }

        do {
          let parts = slug.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: true
          )
          guard parts.count == 2 else {
            throw HubDownloadError.malformedSlug(slug)
          }

          let repo = Repo.ID(namespace: String(parts[0]), name: String(parts[1]))
          let destination = "\(NSHomeDirectory())/.lmstudio/models/\(slug)"
          let destinationURL = URL(fileURLWithPath: destination)

          log.notice(
            "hub.download_started slug=\(slug, privacy: .public) destination=\(destination, privacy: .public)"
          )
          continuation.yield(.started(slug: slug, destination: destination))

          let client = HubClient()
          _ = try await client.downloadSnapshot(
            of: repo,
            to: destinationURL
          ) { progress in
            let pct = Int(progress.fractionCompleted * 100)
            guard pct % 10 == 0 else { return }
            let line = "  \(pct)%  (\(progress.completedUnitCount)/\(progress.totalUnitCount))"
            log.debug(
              "hub.download_progress slug=\(slug, privacy: .public) pct=\(pct, privacy: .public) completed=\(progress.completedUnitCount, privacy: .public) total=\(progress.totalUnitCount, privacy: .public)"
            )
            continuation.yield(.progress(line: line))
          }

          log.notice("hub.download_completed slug=\(slug, privacy: .public)")
          continuation.finish()
        } catch {
          log.error(
            "hub.download_failed slug=\(slug, privacy: .public) err=\(String(describing: error), privacy: .public)"
          )
          continuation.finish(throwing: error)
        }
      }
    }
  }
}
