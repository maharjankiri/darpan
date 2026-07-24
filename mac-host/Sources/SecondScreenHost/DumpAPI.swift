import Foundation
import ObjectiveC

func dumpVirtualDisplayAPI() {
    let classNames = [
        "CGVirtualDisplay",
        "CGVirtualDisplayDescriptor",
        "CGVirtualDisplayMode",
        "CGVirtualDisplaySettings",
    ]

    for name in classNames {
        guard let cls = NSClassFromString(name) else {
            print("\(name): NOT FOUND")
            continue
        }
        print("\n=== \(name) ===")

        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(cls, &methodCount) {
            for i in 0..<Int(methodCount) {
                let sel = method_getName(methods[i])
                print("  - \(NSStringFromSelector(sel))")
            }
            free(methods)
        }

        // Also check properties
        var propCount: UInt32 = 0
        if let props = class_copyPropertyList(cls, &propCount) {
            for i in 0..<Int(propCount) {
                let name = String(cString: property_getName(props[i]))
                let attrs = property_getAttributes(props[i]).map { String(cString: $0) } ?? ""
                print("  [prop] \(name) — \(attrs)")
            }
            free(props)
        }
    }
}
