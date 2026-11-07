// The Mark One camera extension: a virtual camera fed by the E-M5.
//
// The extension doesn't talk to the camera. It has two streams: a source
// stream, which video apps see as the "Mark One" camera, and a sink stream,
// which markone-feed fills with frames from the E-M5. Frames go straight
// from the sink to the source. When no frames have arrived for a moment,
// the source shows a plain placeholder so apps don't freeze.

import CoreMediaIO
import Foundation

let provider = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: provider.provider)
CFRunLoopRun()
