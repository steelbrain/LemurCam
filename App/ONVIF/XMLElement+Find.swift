import XMLKit

extension XMLKit.XMLElement {
    /// Recursively finds elements with the given local name and calls the handler for each.
    func findElements(named name: String, handler: (XMLKit.XMLElement) -> Void) {
        if self.name == name {
            handler(self)
            return
        }
        for child in elementChildren {
            child.findElements(named: name, handler: handler)
        }
    }
}
