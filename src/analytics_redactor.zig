//! Masks secrets in content before analytics write it.
//!
//! Analytics capture a little of each prompt, reply and tool call, and even a
//! few dozen characters can hold an API key someone pasted or a tool printed.
//! This finds the shapes secrets usually take and replaces each with
//! `[redacted]`:
//!
//! - a token after a provider's key prefix (`sk-`, `xai-`, `ghp_`, `AKIA`, …);
//! - the token after `Bearer `;
//! - a JWT (`eyJ…` with two dots);
//! - the value after a secret-sounding key (`password=`, `"token": "…"`);
//! - a PEM private key block.
//!
//! **It is a filter, not a guarantee.** A secret in no recognised shape gets
//! through; `capture_content: false` is the setting that keeps content out
//! altogether.

const std = @import("std");
const log = std.log.scoped(.acp_analytics_redactor);
const acp = @import("module.zig");

/// Finds secret-shaped text and replaces it.
pub const AnalyticsRedactor = struct {
    const Self = @This();

    /// What a secret is replaced with.
    pub const replacement = "[redacted]";

    /// How far past the kept content to look, so a secret the cut would split
    /// is still seen whole; longer than any key in a recognised shape.
    pub const window_overrun = 256;

    /// Shortest token after a prefix or `Bearer ` that counts as a secret, so
    /// prose such as `sk-learn` is left alone.
    const min_token_len = 16;

    /// Shortest value after a secret-sounding key that counts as a secret.
    const min_value_len = 4;

    /// Shortest JWT taken for one.
    const min_jwt_len = 30;

    /// Prefixes providers put on their keys.
    const key_prefixes = [_][]const u8{
        "sk-",    "xai-",  "ghp_",  "gho_",     "ghu_",     "ghs_",     "ghr_",
        "glpat-", "xoxb-", "xoxp-", "xoxa-",    "xoxr-",    "AKIA",     "ASIA",
        "AIza",   "hf_",   "npm_",  "sk_live_", "sk_test_", "rk_live_", "github_pat_",
    };

    /// Keys whose value is a secret, matched without regard to case.
    const secret_keys = [_][]const u8{ "password", "passwd", "secret", "api_key", "apikey", "api-key", "access_token", "auth_token", "token", "private_key", "client_secret" };

    /// Where a secret was found.
    const Match = struct {
        /// The end of the text kept before the replacement, such as `password=`.
        keep_end: usize,
        /// The end of the secret.
        end: usize,
    };

    /// Copies text with every secret in it replaced.
    ///
    /// Parameters:
    /// - `allocator`: owns the copy.
    /// - `text`: the content; borrowed for the call.
    ///
    /// Return: the redacted copy, caller frees; propagates allocation failure.
    pub fn redactAlloc(allocator: std.mem.Allocator, text: []const u8) acp.AcpError![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var index: usize = 0;
        var found: usize = 0;
        while (index < text.len) {
            if (matchAt(text, index)) |match| {
                out.writer.writeAll(text[index..match.keep_end]) catch return error.OutOfMemory;
                out.writer.writeAll(replacement) catch return error.OutOfMemory;
                index = match.end;
                found += 1;
                continue;
            }
            out.writer.writeByte(text[index]) catch return error.OutOfMemory;
            index += 1;
        }
        if (found > 0) log.debug("{d} secret(s) redacted", .{found});
        return out.toOwnedSlice();
    }

    /// Looks for a secret starting at one position.
    ///
    /// Parameters:
    /// - `text`: the content.
    /// - `index`: where to look.
    ///
    /// Return: the match, or null when none starts there.
    fn matchAt(text: []const u8, index: usize) ?Match {
        const rest = text[index..];

        // A private key is replaced whole, through its END line when it has one.
        if (std.mem.startsWith(u8, rest, "-----BEGIN ")) {
            const head_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
            if (std.mem.find(u8, rest[0..head_end], "PRIVATE KEY") != null) {
                const end = if (std.mem.find(u8, rest, "-----END ")) |at| blk: {
                    const tail = std.mem.findPos(u8, rest, at + 9, "-----") orelse break :blk rest.len;
                    break :blk tail + 5;
                } else rest.len;
                return .{ .keep_end = index, .end = index + end };
            }
        }

        // Everything else starts a word: `ask-me` holds no `sk-` key.
        if (index > 0 and isTokenChar(text[index - 1])) return null;

        for (key_prefixes) |prefix| {
            if (!std.mem.startsWith(u8, rest, prefix)) continue;
            const end = scan(text, index + prefix.len, isTokenChar);
            if (end - (index + prefix.len) >= min_token_len) return .{ .keep_end = index, .end = end };
        }

        if (rest.len > 7 and std.ascii.eqlIgnoreCase(rest[0..7], "bearer ")) {
            const end = scan(text, index + 7, isBearerChar);
            if (end - (index + 7) >= min_token_len) return .{ .keep_end = index + 7, .end = end };
        }

        if (std.mem.startsWith(u8, rest, "eyJ")) {
            const end = scan(text, index, isJwtChar);
            if (end - index >= min_jwt_len and std.mem.count(u8, text[index..end], ".") == 2) return .{ .keep_end = index, .end = end };
        }

        for (secret_keys) |key| {
            if (rest.len <= key.len or !std.ascii.eqlIgnoreCase(rest[0..key.len], key)) continue;
            if (isTokenChar(rest[key.len])) continue;
            // `key`, an optional closing quote, spaces, `=` or `:`, spaces, an optional opening quote.
            var at = index + key.len;
            if (at < text.len and (text[at] == '"' or text[at] == '\'')) at += 1;
            at = scan(text, at, isSpace);
            if (at >= text.len or (text[at] != '=' and text[at] != ':')) continue;
            at = scan(text, at + 1, isSpace);
            if (at < text.len and (text[at] == '"' or text[at] == '\'')) at += 1;
            const end = scan(text, at, isValueChar);
            if (end - at >= min_value_len) return .{ .keep_end = at, .end = end };
        }
        return null;
    }

    /// Advances past every byte a predicate accepts.
    ///
    /// Parameters:
    /// - `text`: the content.
    /// - `from`: where to start.
    /// - `accepts`: the predicate.
    ///
    /// Return: the first index it rejects, or the end.
    fn scan(text: []const u8, from: usize, comptime accepts: fn (u8) bool) usize {
        var at = from;
        while (at < text.len and accepts(text[at])) at += 1;
        return at;
    }

    /// Reports whether a byte is a byte that can be part of a key or a word.
    ///
    /// Parameters:
    /// - `byte`: the byte.
    ///
    /// Return: true when it is.
    fn isTokenChar(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
    }

    /// Reports whether a byte is a byte that can be part of a bearer token, base64 included.
    ///
    /// Parameters:
    /// - `byte`: the byte.
    ///
    /// Return: true when it is.
    fn isBearerChar(byte: u8) bool {
        return isTokenChar(byte) or byte == '.' or byte == '~' or byte == '+' or byte == '/' or byte == '=';
    }

    /// Reports whether a byte is a byte that can be part of a JWT.
    ///
    /// Parameters:
    /// - `byte`: the byte.
    ///
    /// Return: true when it is.
    fn isJwtChar(byte: u8) bool {
        return isTokenChar(byte) or byte == '.';
    }

    /// Reports whether a byte is a byte that can be part of a value after a key.
    ///
    /// Parameters:
    /// - `byte`: the byte.
    ///
    /// Return: true when it is.
    fn isValueChar(byte: u8) bool {
        return !std.ascii.isWhitespace(byte) and byte != '"' and byte != '\'' and byte != ',' and byte != '&' and byte != ';' and byte != '}';
    }

    /// Reports whether a byte is a space or tab between a key and its value.
    ///
    /// Parameters:
    /// - `byte`: the byte.
    ///
    /// Return: true when it is.
    fn isSpace(byte: u8) bool {
        return byte == ' ' or byte == '\t';
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AnalyticsRedactor);
}

/// Redacts text and checks the result.
///
/// Parameters:
/// - `text`: the content.
/// - `expected`: what it should become.
///
/// Return: nothing; fails the test on a mismatch.
fn expectRedacted(text: []const u8, expected: []const u8) !void {
    const redacted = try AnalyticsRedactor.redactAlloc(std.testing.allocator, text);
    defer std.testing.allocator.free(redacted);
    try std.testing.expectEqualStrings(expected, redacted);
}

test "provider keys, bearer tokens and JWTs are replaced, and prose is left alone" {
    try expectRedacted("key sk-ant-api03-abcdefghijklmnopqrstu done", "key [redacted] done");
    try expectRedacted("AKIAABCDEFGHIJKLMNOP", "[redacted]");
    try expectRedacted("Authorization: Bearer 0123456789abcdef0123", "Authorization: Bearer [redacted]");
    try expectRedacted("t=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", "t=[redacted]");
    // Too short to be a key, or not at the start of a word.
    try expectRedacted("use sk-learn and ask-me-anything-about-it-please", "use sk-learn and ask-me-anything-about-it-please");
    try expectRedacted("Bearer of bad news", "Bearer of bad news");
}

test "the value after a secret-sounding key is replaced, in env, prose and JSON" {
    try expectRedacted("PASSWORD=hunter22 next", "PASSWORD=[redacted] next");
    try expectRedacted("{\"api_key\": \"abcd1234\", \"n\": 1}", "{\"api_key\": \"[redacted]\", \"n\": 1}");
    try expectRedacted("token: 5f2e9a", "token: [redacted]");
    // Not a key/value pair, or a value too short to be a secret.
    try expectRedacted("the token count is 512", "the token count is 512");
    try expectRedacted("max_tokens=4096", "max_tokens=4096");
    try expectRedacted("token: 42", "token: 42");
}

test "a private key block is replaced whole" {
    try expectRedacted("a\n-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----\nb", "a\n[redacted]\nb");
    try expectRedacted("-----BEGIN PUBLIC KEY-----", "-----BEGIN PUBLIC KEY-----");
}
