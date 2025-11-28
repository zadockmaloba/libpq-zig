const std = @import("std");
const zeit = @import("zeit");

pub fn unixTimeFromISO8601(date: []const u8) !i64 {
    const instance = try zeit.instant(.{ .source = .{ .iso8601 = date } });
    return @intCast(@divExact(instance.milliTimestamp(), 1000));
}

pub fn unixTimeToISO8601(allocator: std.mem.Allocator, sec_timestamp: i64) ![]const u8 {
    var ret: std.ArrayList(u8) = .empty;
    defer ret.deinit(allocator);
    const instance = try zeit.instant(.{ .source = .{ .unix_timestamp = sec_timestamp } });

    const time = instance.time();

    try time.strftime(ret.writer(allocator), "%Y-%m-%dT%H:%M:%S");

    return ret.toOwnedSlice(allocator);
}

pub fn unixTimeToISO8601Z(allocator: std.mem.Allocator, sec_timestamp: i64) ![]const u8 {
    var ret: std.ArrayList(u8) = .empty;
    defer ret.deinit(allocator);
    const instance = try zeit.instant(.{ .source = .{ .unix_timestamp = sec_timestamp } });

    const time = instance.time();

    try time.strftime(ret.writer(allocator), "%Y-%m-%dT%H:%M:%SZ");

    return ret.toOwnedSlice(allocator);
}

// Tests
test "unixTimeFromISO8601 - valid ISO8601 string" {
    // Test a known timestamp: 2023-12-25T15:30:45Z
    const iso_date = "2023-12-25T15:30:45Z";
    const unix_time = try unixTimeFromISO8601(iso_date);

    // Expected Unix timestamp for 2023-12-25 15:30:45 UTC
    const expected: i64 = 1703518245;
    try std.testing.expectEqual(expected, unix_time);
}

test "unixTimeFromISO8601 - epoch time" {
    const iso_date = "1970-01-01T00:00:00Z";
    const unix_time = try unixTimeFromISO8601(iso_date);
    try std.testing.expectEqual(@as(i64, 0), unix_time);
}

test "unixTimeFromISO8601 - various formats" {
    // Test with different ISO8601 formats
    const test_cases = [_]struct {
        input: []const u8,
        expected_range_start: i64,
        expected_range_end: i64,
    }{
        .{
            .input = "2024-01-01T00:00:00Z",
            .expected_range_start = 1704067200,
            .expected_range_end = 1704067200,
        },
        .{
            .input = "2024-06-15T12:30:00Z",
            .expected_range_start = 1718454600,
            .expected_range_end = 1718454600,
        },
    };

    for (test_cases) |tc| {
        const unix_time = try unixTimeFromISO8601(tc.input);
        try std.testing.expect(unix_time >= tc.expected_range_start);
        try std.testing.expect(unix_time <= tc.expected_range_end);
    }
}

test "unixTimeToISO8601 - valid unix timestamp" {
    const allocator = std.testing.allocator;

    // Test converting Unix timestamp back to ISO8601
    const unix_time: i64 = 1703518245; // 2023-12-25T15:30:45Z
    const iso_string = try unixTimeToISO8601(allocator, unix_time);
    defer allocator.free(iso_string);

    // Should be in format YYYY-MM-DDTHH:MM:SS (without Z)
    try std.testing.expectEqualStrings("2023-12-25T15:30:45", iso_string);
}

test "unixTimeToISO8601 - epoch time" {
    const allocator = std.testing.allocator;

    const unix_time: i64 = 0;
    const iso_string = try unixTimeToISO8601(allocator, unix_time);
    defer allocator.free(iso_string);

    try std.testing.expectEqualStrings("1970-01-01T00:00:00", iso_string);
}

test "unixTimeToISO8601Z - valid unix timestamp with Z suffix" {
    const allocator = std.testing.allocator;

    const unix_time: i64 = 1703518245; // 2023-12-25T15:30:45Z
    const iso_string = try unixTimeToISO8601Z(allocator, unix_time);
    defer allocator.free(iso_string);

    // Should be in format YYYY-MM-DDTHH:MM:SSZ (with Z)
    try std.testing.expectEqualStrings("2023-12-25T15:30:45Z", iso_string);
}

test "unixTimeToISO8601Z - epoch time with Z suffix" {
    const allocator = std.testing.allocator;

    const unix_time: i64 = 0;
    const iso_string = try unixTimeToISO8601Z(allocator, unix_time);
    defer allocator.free(iso_string);

    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", iso_string);
}

test "roundtrip conversion - ISO8601 to Unix and back" {
    const allocator = std.testing.allocator;

    const original_iso = "2024-11-22T10:15:30Z";

    // Convert to Unix time
    const unix_time = try unixTimeFromISO8601(original_iso);

    // Convert back to ISO8601
    const roundtrip_iso = try unixTimeToISO8601Z(allocator, unix_time);
    defer allocator.free(roundtrip_iso);

    // Should match the original
    try std.testing.expectEqualStrings(original_iso, roundtrip_iso);
}

test "unixTimeToISO8601 - multiple conversions" {
    const allocator = std.testing.allocator;

    const test_cases = [_]struct {
        unix_time: i64,
        expected: []const u8,
    }{
        .{ .unix_time = 1609459200, .expected = "2021-01-01T00:00:00" },
        .{ .unix_time = 1672531200, .expected = "2023-01-01T00:00:00" },
    };

    for (test_cases) |tc| {
        const iso_string = try unixTimeToISO8601(allocator, tc.unix_time);
        defer allocator.free(iso_string);
        try std.testing.expectEqualStrings(tc.expected, iso_string);
    }
}

test "unixTimeFromISO8601 - negative unix time (before epoch)" {
    // Test dates before Unix epoch
    const iso_date = "1969-12-31T23:59:59Z";
    const unix_time = try unixTimeFromISO8601(iso_date);

    // Should be negative
    try std.testing.expect(unix_time < 0);
}

test "unixTimeToISO8601Z - future date" {
    const allocator = std.testing.allocator;

    // Test a date far in the future: 2050-01-01T00:00:00Z
    const unix_time: i64 = 2524608000;
    const iso_string = try unixTimeToISO8601Z(allocator, unix_time);
    defer allocator.free(iso_string);

    try std.testing.expectEqualStrings("2050-01-01T00:00:00Z", iso_string);
}
