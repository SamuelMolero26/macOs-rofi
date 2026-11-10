import Foundation

/// A template that failed to expand or split, worded as rofi's error dialog
/// (`helper_parse_setup`, source/helper.c:136-137).
public struct CommandTemplateError: Error, Equatable {
    public let message: String
}

/// `helper_parse_setup` (source/helper.c:102-144): substitutes `{name}`
/// placeholders and `[ ... {name} ... ]` optional groups, then splits the
/// result with `g_shell_parse_argv` semantics. No shell is involved.
///
/// `values` is keyed by the bare name (`"host"` for `{host}`). Upstream also
/// seeds `{terminal}` and `{ssh-client}` from the configuration (helper.c:107-108);
/// the caller supplies them here. Callers: run.c / helper.c:1456-1459
/// (`{cmd}`), ssh.c:105-119 (`{host}`, `{port}`, `{cmd}`).
///
/// Injection safety: like upstream, substitution happens on the text BEFORE
/// splitting (helper.c:125-129), so an unquoted value containing blanks or
/// quotes is split into several arguments. Templates that need one argument
/// must quote the placeholder (`"{cmd}"`). Nothing is ever expanded
/// (`$HOME`, backticks, globs stay literal) and no shell runs the result.
public func parseCommandTemplate(_ template: String, values: [String: String]) throws -> [String] {
    let expanded = expandPlaceholders(template, values: values)
    do {
        return try shellParseArgv(expanded)
    } catch {
        throw CommandTemplateError(
            message: "Failed to parse: '\(template)'\nError: '\(error.message)'")
    }
}

/// `helper_string_replace_if_exists_v` (helper.c:1814-1839) with `helper_eval_cb2`
/// (helper.c:1733-1777). The upstream pattern is compiled UNGREEDY, so every
/// quantifier is lazy here. `\w` is ASCII in PCRE, hence the explicit class.
private let placeholderPattern: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(
        pattern: #"\[(.*?)(\{[-A-Za-z0-9_]+\})(.*?)\]|(\{[-A-Za-z0-9_]+\})"#)
}()

private func expandPlaceholders(_ template: String, values: [String: String]) -> String {
    let source = template as NSString
    var result = ""
    var cursor = 0
    for match in placeholderPattern.matches(in: template, range: NSRange(location: 0, length: source.length)) {
        result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        cursor = match.range.location + match.range.length
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }
        if let bare = group(4) {
            // A lone {name}: the value, or nothing when unknown (helper.c:1743-1747).
            result += values[unbraced(bare)] ?? ""
        } else if let key = group(2), let value = values[unbraced(key)] {
            // Guarded by [...]: kept with brackets removed only when the key is
            // known; an empty value still counts (helper.c:1757-1768).
            result += (group(1) ?? "") + value + (group(3) ?? "")
        }
        // Unknown key inside [...]: the whole group is dropped.
    }
    result += source.substring(from: cursor)
    return result
}

private func unbraced(_ placeholder: String) -> String {
    String(placeholder.dropFirst().dropLast())
}
