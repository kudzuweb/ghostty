const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 7501. The payload is passed through unparsed; the apprt
/// interprets it.
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"7501");
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    parser.command = .{
        .program_status = .{
            .payload = data[0 .. data.len - 1 :0],
        },
    };
    return &parser.command;
}

test "OSC 7501: capability query" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7501;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\\').?.*;
    try testing.expect(cmd == .program_status);
    try testing.expectEqualStrings("?", cmd.program_status.payload);
}

test "OSC 7501: state payload" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7501;state=blocked:app=claude-code:kind=permission:msg=aGk=";
    for (input) |ch| p.next(ch);

    const cmd = p.end(0x07).?.*;
    try testing.expect(cmd == .program_status);
    try testing.expectEqualStrings(
        "state=blocked:app=claude-code:kind=permission:msg=aGk=",
        cmd.program_status.payload,
    );
}

test "OSC 7501: empty payload" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7501;";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .program_status);
    try testing.expectEqualStrings("", cmd.program_status.payload);
}

test "OSC 7501: no payload separator" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7501";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
}

test "OSC 7501: longer than buffer" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7501;" ++ "a" ** (Parser.MAX_BUF + 2);
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
}

test "OSC 750: not a command" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "750;state=idle";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
}
