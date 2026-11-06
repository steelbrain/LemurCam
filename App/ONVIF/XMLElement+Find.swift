import XMLKit

extension XMLKit.XMLElement {
    /// Finds elements with the given local name, in document order, and calls the
    /// handler for each. A matched element is not searched further, so a same-named
    /// element nested inside a match is not visited. Walks the tree with an explicit
    /// stack rather than recursion, so nesting depth cannot exhaust the thread stack.
    func findElements(named name: String, handler: (XMLKit.XMLElement) -> Void) {
        var pending: [XMLKit.XMLElement] = [self]
        while let element = pending.popLast() {
            if element.name == name {
                handler(element)
                continue
            }
            pending.append(contentsOf: element.elementChildren.reversed())
        }
    }
}
