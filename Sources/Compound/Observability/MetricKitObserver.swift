import Foundation

#if canImport(MetricKit) && (os(iOS) || os(macOS) || os(visionOS))
import MetricKit

/// Bridges Apple's MetricKit into the Compound observability story.
///
/// MetricKit delivers aggregated app-health payloads (launch time,
/// hangs, CPU, memory, energy) on a daily cadence (or on-demand in
/// development builds). These are orthogonal to Compound's per-run
/// ``TraceEvent`` stream but valuable for the operations side of any
/// production iOS app.
///
/// Construct, retain, and call ``start()`` once at app launch — typically
/// from the App delegate or a SwiftUI `App`'s `init`. Payloads are
/// forwarded to the supplied handler.
@available(iOS 13.0, macOS 12.0, visionOS 1.0, *)
public final class MetricKitObserver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    /// Closure called with each batch of `MXMetricPayload` deliveries.
    public typealias MetricHandler = @Sendable ([MXMetricPayload]) -> Void
    /// Closure called with each batch of `MXDiagnosticPayload` deliveries.
    public typealias DiagnosticHandler = @Sendable ([MXDiagnosticPayload]) -> Void

    private let metricHandler: MetricHandler
    private let diagnosticHandler: DiagnosticHandler?

    /// Creates an observer.
    ///
    /// - Parameters:
    ///   - onMetrics: Handler invoked when MetricKit delivers payloads.
    ///   - onDiagnostics: Optional handler for diagnostic payloads.
    public init(
        onMetrics: @escaping MetricHandler,
        onDiagnostics: DiagnosticHandler? = nil
    ) {
        self.metricHandler = onMetrics
        self.diagnosticHandler = onDiagnostics
        super.init()
    }

    /// Subscribes to the shared `MXMetricManager`.
    public func start() {
        MXMetricManager.shared.add(self)
    }

    /// Unsubscribes from the shared `MXMetricManager`.
    public func stop() {
        MXMetricManager.shared.remove(self)
    }

    /// MetricKit delivery hook for `MXMetricPayload` batches.
    public func didReceive(_ payloads: [MXMetricPayload]) {
        metricHandler(payloads)
    }

    /// MetricKit delivery hook for `MXDiagnosticPayload` batches.
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        diagnosticHandler?(payloads)
    }
}
#endif
