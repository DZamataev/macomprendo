import Foundation

/// Turns a stream of once-a-second active-call answers into start/stop decisions, with the
/// 3 s start filter, the 15 s stop grace and the hand-stop suppression. Pure, so every timing
/// edge is a unit test.
struct AutoCallRecordPolicy: Sendable {
    enum Decision: Equatable {
        case start(CallApp)
        case stop
    }

    static let startAfter: TimeInterval = 3
    static let stopAfter: TimeInterval = 15

    /// The first tick of the current unbroken run of an active call.
    private var callSince: Date?
    /// The first tick of the current run of no active call.
    private var quietSince: Date?
    /// A recording this policy started is running — it may be stopped by `.stop`.
    private var ownRecording = false
    /// The user stopped our recording by hand; no new start until the call is over.
    private var suppressed = false

    init() {}

    /// One poll. `recorderBusy` is `CallRecordingController.isRecording`.
    mutating func observe(_ call: CallApp?, at now: Date,
                          recorderBusy: Bool) -> Decision? {
        if let call {
            callSince = callSince ?? now
            quietSince = nil
        } else {
            quietSince = quietSince ?? now
            callSince = nil
        }

        // Our recording ended without the policy asking for it: the user stopped it by hand.
        // The recorder's `failed` state is indistinguishable here, so a failed start also
        // suppresses the rest of the call rather than retrying every second.
        if ownRecording, !recorderBusy {
            ownRecording = false
            suppressed = true
        }

        // The suppression lasts until the call has been gone for the same 15 s a stop needs.
        if suppressed, call == nil, let quietSince,
           now.timeIntervalSince(quietSince) >= Self.stopAfter {
            suppressed = false
        }

        if ownRecording {
            guard recorderBusy else { return nil }
            guard call == nil, let quietSince,
                  now.timeIntervalSince(quietSince) >= Self.stopAfter else { return nil }
            ownRecording = false
            return .stop
        }

        if let call, !recorderBusy, !suppressed, let callSince,
           now.timeIntervalSince(callSince) >= Self.startAfter {
            ownRecording = true
            return .start(call)
        }
        return nil
    }
}
