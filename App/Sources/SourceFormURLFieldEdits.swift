/// Tells the user's edits of the URL field apart from the form rewriting it. Connect
/// moves `user:password@` out of an RTSP URL by rewriting the field; the field's
/// change handler resets the form after a user edit, and without this it also
/// treated the rewrite as one, undoing the Connect and hiding the Add button.
internal struct SourceFormURLFieldEdits {
    private var pendingRewrite: String?

    /// Call just before the form sets the field to `text` itself.
    mutating func rewrite(to text: String) {
        pendingRewrite = text
    }

    /// Sets `field` to `text` as the form's own change. Compares with what the field
    /// holds, so a URL that only lost its surrounding spaces is written back too.
    mutating func replace(_ field: inout String, with text: String) {
        guard field != text else { return }
        rewrite(to: text)
        field = text
    }

    /// Whether the field's new value came from the user.
    mutating func isUserEdit(_ newText: String) -> Bool {
        defer { pendingRewrite = nil }
        return pendingRewrite != newText
    }
}
