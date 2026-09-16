import Foundation
enum AppResources {
    static let bundle: Bundle = {
        if let resource = Bundle.main.resourceURL,
           let packaged = Bundle(url: resource.appendingPathComponent("ZipRipper_ZipRipperApp.bundle")) { return packaged }
        #if ZIPRIPPER_PACKAGED
        fatalError("The application resource bundle is missing.")
        #else
        return Bundle.module
        #endif
    }()
}
