import Foundation
enum CoreResources {
    static let bundle: Bundle = {
        if let resource = Bundle.main.resourceURL,
           let packaged = Bundle(url: resource.appendingPathComponent("ZipRipper_ZipRipperCore.bundle")) { return packaged }
        #if ZIPRIPPER_PACKAGED
        fatalError("The recovery resource bundle is missing.")
        #else
        return Bundle.module
        #endif
    }()
}
