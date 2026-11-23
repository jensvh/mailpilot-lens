import Foundation
import MWDATCore
import MWDATInputs

/// What a button or a gesture on the glasses means to a walk.
enum FrameSignal: Equatable {
    /// The capture button or the action button: open the microphone.
    case talk
    /// The back gesture, which the app now gets instead of being closed by it.
    case back
}

/// The glasses' own buttons and gestures (MWDATInputs, which Meta marks as
/// experimental): the capture button, the action button, the touch strip on
/// the frame and the Neural Band, as events on the session that also carries
/// the lens.
///
/// Off unless chosen in Settings, because nobody has seen yet what it does to
/// a card: if the glasses hand a pinch to this instead of to the card's
/// buttons, cards stop working. Every event is logged, so one walk tells.
@MainActor
final class FrameInputs {
    var onSignal: ((FrameSignal) -> Void)?

    private var inputs: Inputs?
    private var tasks: [Task<Void, Never>] = []
    private var tokens: [any AnyListenerToken] = []
    private var gen = 0
    private var asked = false

    /// Asks the session for the inputs, once per session. A refusal is logged and nothing else: the walk goes on
    /// without them.
    func attach(to session: DeviceSession) {
        guard !asked else { return }
        asked = true
        // No drags: they come many times a second and nothing here uses them.
        let wanted = InputsConfiguration(sources: [.captureButton, .actionButton, .captouch, .neuralBand], consumeBack: true)
        do {
            guard let opened = try session.addInputs(configuration: wanted) else {
                Log.say("frame: these glasses offer no inputs")
                return
            }
            gen += 1
            let mine = gen
            inputs = opened
            Log.say("frame: inputs asked for (\(opened.state))")
            tokens.append(opened.statePublisher.listen { state in
                Log.say("frame: inputs \(state)")
            })
            tokens.append(opened.errorPublisher.listen { error in
                Log.say("frame: inputs error: \(error.description)")
            })
            tasks.append(Task { [weak self] in
                for await event in opened.events {
                    guard let self, self.gen == mine else { return }
                    self.received(event)
                }
            })
        } catch {
            Log.say("frame: inputs refused: \(Glasses.explain(error))")
        }
    }

    /// The session is gone, and its inputs with it.
    func drop() {
        gen += 1
        inputs = nil
        asked = false
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        let old = tokens
        tokens = []
        Task { for token in old { await token.cancel() } }
    }

    private func received(_ event: InputEvent) {
        switch event {
        case .capture(let press, let source, _):
            Log.say("frame: capture button \(press) (\(source))")
            if press == .shortPress { onSignal?(.talk) }
        case .button(let button, let source, _):
            Log.say("frame: button \(button) (\(source))")
            onSignal?(.talk)
        case .back(let source, _):
            Log.say("frame: back (\(source))")
            onSignal?(.back)
        case .nav(let direction, let source, _):
            // Only logged: on a card a swipe may move the focus between its buttons too.
            Log.say("frame: swipe \(direction) (\(source))")
        case .select(let source, _):
            Log.say("frame: select (\(source))")
        case .drag:
            break
        @unknown default:
            Log.say("frame: an input this build doesn't know")
        }
    }
}
