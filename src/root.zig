const std = @import("std");

const libpq = @cImport({
    @cInclude("libpq-fe.h");
});

pub fn get_db_host_env() []const u8 {
    // Check for environment variable, default to localhost for local development
    return std.process.getEnvVarOwned(std.heap.page_allocator, "DB_HOST") catch "localhost";
}

const PostgresError = error{
    BufferInsertFailed,
    ConnectionFailed,
    ConnectionLost,
    InvalidConnectionString,
    AuthenticationFailed,
    QueryFailed,
    InvalidQuery,
    NoSuchTable,
    NoSuchColumn,
    PermissionDenied,
    TransactionBeginFailed,
    TransactionCommitFailed,
    TransactionRollbackFailed,
    TypeMismatch,
    InvalidUTF8,
    NullValue,
    QueryTimeout,
    ConnectionTimeout,
    NetworkError,
    SSLHandshakeFailed,
    ProtocolViolation,
    InvalidMessage,
    OutOfMemory,
    InternalError,
    Cancelled,
    ParameterBindingFailed,
    PreparedStatementFailed,
    InvalidColumnIndex,
    ResultSetExhausted,
    PoolExhausted,
    InvalidSSLConfig,
};

pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,
};

pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    microsecond: u32,
};

pub const DateTime = struct {
    date: Date,
    time: Time,
};

pub const DateTimeTz = struct {
    datetime: DateTime,
    timezone_offset: i32, // seconds from UTC
};

pub const PgType = union(enum) {
    // Numeric types
    smallint: i16,
    integer: i32,
    bigint: i64,
    real: f32,
    double: f64,
    numeric: []const u8, // For precision decimals

    // Text types
    char: u8,
    varchar: []const u8,
    text: []const u8,

    // Date/Time types
    date: Date,
    time: Time,
    timestamp: DateTime,
    timestamptz: DateTimeTz,

    // Boolean
    boolean: bool,

    // Binary
    bytea: []const u8,

    // JSON
    json: []const u8,
    jsonb: []const u8,

    // Arrays
    array: []PgType,

    // UUID
    uuid: [16]u8,

    // NULL
    null: void,

    // Legacy support
    string: []const u8,
    number: i64,
};

pub const PostgresErrorInfo = struct {
    message: []const u8,
    sqlstate: []const u8,
    severity: []const u8,
    detail: []const u8,
    hint: []const u8,
};

pub const SSLConfig = struct {
    mode: enum { disable, allow, prefer, require, verify_ca, verify_full },
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    ca_file: ?[]const u8 = null,
};

pub const Row = struct {
    result: *libpq.PGresult,
    row_index: i32,
    allocator: std.mem.Allocator,

    pub fn get(self: *const @This(), column: []const u8, comptime T: type) !T {
        const col_index = libpq.PQfnumber(self.result, column.ptr);
        if (col_index == -1) return PostgresError.NoSuchColumn;

        if (libpq.PQgetisnull(self.result, self.row_index, col_index) == 1) {
            return PostgresError.NullValue;
        }

        const value = libpq.PQgetvalue(self.result, self.row_index, col_index);
        return parseValue(T, std.mem.span(value));
    }

    pub fn getOpt(self: *const @This(), column: []const u8, comptime T: type) !?T {
        const col_index = libpq.PQfnumber(self.result, column.ptr);
        if (col_index == -1) return PostgresError.NoSuchColumn;

        if (libpq.PQgetisnull(self.result, self.row_index, col_index) == 1) {
            return null;
        }

        const value = libpq.PQgetvalue(self.result, self.row_index, col_index);
        const ret = try parseValue(T, std.mem.span(value));
        return ret;
    }
};

pub const ResultSet = struct {
    result: *libpq.PGresult,
    current_row: i32,
    total_rows: i32,
    allocator: std.mem.Allocator,

    pub fn init(result: *libpq.PGresult, allocator: std.mem.Allocator) ResultSet {
        return ResultSet{
            .result = result,
            .current_row = 0,
            .total_rows = libpq.PQntuples(result),
            .allocator = allocator,
        };
    }

    pub fn next(self: *@This()) ?Row {
        if (self.current_row >= self.total_rows) return null;
        defer self.current_row += 1;
        return Row{
            .result = self.result,
            .row_index = self.current_row,
            .allocator = self.allocator,
        };
    }

    pub fn rowCount(self: *@This()) i32 {
        return self.total_rows;
    }

    pub fn columnCount(self: *@This()) i32 {
        return libpq.PQnfields(self.result);
    }
};

pub const QueryBuilder = struct {
    query: std.ArrayList(u8),
    params: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) QueryBuilder {
        return QueryBuilder{
            .query = .empty,
            .params = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.query.deinit(self.allocator);
        for (self.params.items) |param| {
            self.allocator.free(param);
        }
        self.params.deinit(self.allocator);
    }

    pub fn sql(self: *@This(), text: []const u8) !*@This() {
        try self.query.appendSlice(self.allocator, text);
        return self;
    }

    pub fn bind(self: *@This(), value: anytype) !*@This() {
        const param_index = self.params.items.len + 1;
        try self.query.writer(self.allocator).print("${d}", .{param_index});

        const str_value = try valueToString(self.allocator, value);
        try self.params.append(self.allocator, str_value);
        return self;
    }

    pub fn build(self: *@This()) []const u8 {
        return self.query.items;
    }
};

fn parseValue(comptime T: type, value: []const u8) !T {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .int => {
            return std.fmt.parseInt(T, value, 10);
        },
        .float => {
            return std.fmt.parseFloat(T, value);
        },
        .bool => {
            return std.mem.eql(u8, value, "t") or std.mem.eql(u8, value, "true");
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.child == u8) {
                        // Handle []const u8, []u8
                        return value;
                    }
                },
                else => {},
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                // Handle [N]u8, [N:0]u8 - but this requires copying into a fixed array
                // For now, we'll return an error as we can't safely convert
                @compileError("Cannot parse into fixed-size array type " ++ @typeName(T) ++ ". Use []const u8 instead.");
            }
        },
        else => {},
    }

    @compileError("Unsupported type for parseValue: " ++ @typeName(T));
}

fn valueToString(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    switch (type_info) {
        .int => return std.fmt.allocPrint(allocator, "{d}", .{value}),
        .float => return std.fmt.allocPrint(allocator, "{d}", .{value}),
        .bool => return allocator.dupe(u8, if (value) "true" else "false"),
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .one => {
                    // Handle *const [N:0]u8, *const [N]u8, etc.
                    const child_info = @typeInfo(ptr_info.child);
                    if (child_info == .array) {
                        const array_info = child_info.array;
                        if (array_info.child == u8) {
                            // Convert array pointer to slice
                            const slice: []const u8 = value;
                            return allocator.dupe(u8, slice);
                        }
                    }
                    return std.fmt.allocPrint(allocator, "{any}", .{value});
                },
                .many => {
                    if (ptr_info.child == u8) {
                        // Handle [*:0]const u8, [*]const u8
                        if (std.builtin.Type.Pointer.sentinel(ptr_info)) |sentinel| {
                            if (sentinel == 0) {
                                // Null-terminated string
                                const slice = std.mem.span(value);
                                return allocator.dupe(u8, slice);
                            }
                        }
                        // For non-null-terminated, we can't safely determine length
                        return std.fmt.allocPrint(allocator, "{any}", .{value});
                    }
                    return std.fmt.allocPrint(allocator, "{any}", .{value});
                },
                .slice => {
                    if (ptr_info.child == u8) {
                        // Handle []u8, []const u8
                        return allocator.dupe(u8, value);
                    }
                    return std.fmt.allocPrint(allocator, "{any}", .{value});
                },
                .c => {
                    if (ptr_info.child == u8) {
                        // Handle [*c]const u8
                        const slice = std.mem.span(value);
                        return allocator.dupe(u8, slice);
                    }
                    return std.fmt.allocPrint(allocator, "{any}", .{value});
                },
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                // Handle [N]u8, [N:0]u8
                const slice: []const u8 = &value;
                if (std.builtin.Type.Array.sentinel(array_info)) |sentinel| {
                    if (sentinel == 0) {
                        // Null-terminated array, find actual length
                        const len = std.mem.indexOfScalar(u8, slice, 0) orelse slice.len;
                        return allocator.dupe(u8, slice[0..len]);
                    }
                }
                return allocator.dupe(u8, slice);
            }
            return std.fmt.allocPrint(allocator, "{any}", .{value});
        },
        .optional => {
            if (value) |val| {
                return valueToString(allocator, val);
            } else {
                return allocator.dupe(u8, "null");
            }
        },
        else => {
            // Fallback for other types
            return std.fmt.allocPrint(allocator, "{any}", .{value});
        },
    }
}

pub const ConnectionPool = struct {
    connections: std.ArrayList(*Connection),
    available: std.ArrayList(*Connection),
    mutex: std.Thread.Mutex,
    max_connections: u32,
    min_connections: u32,
    allocator: std.mem.Allocator,
    connection_string: []const u8,

    pub fn init(allocator: std.mem.Allocator, connection_string: []const u8, min_connections: u32, max_connections: u32) !ConnectionPool {
        var pool = ConnectionPool{
            .connections = try .initCapacity(allocator, max_connections),
            .available = try .initCapacity(allocator, max_connections),
            .mutex = std.Thread.Mutex{},
            .max_connections = max_connections,
            .min_connections = min_connections,
            .allocator = allocator,
            .connection_string = try allocator.dupe(u8, connection_string),
        };

        // Create minimum connections
        for (0..min_connections) |_| {
            const conn = try allocator.create(Connection);
            conn.* = Connection.init(allocator);
            try conn.connect(connection_string);
            try pool.connections.append(allocator, conn);
            try pool.available.append(allocator, conn);
        }

        return pool;
    }

    pub fn deinit(self: *@This()) void {
        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
        self.allocator.free(self.connection_string);
    }

    pub fn acquire(self: *@This()) !*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.items.len > 0) {
            return self.available.pop().?;
        }

        if (self.connections.items.len < self.max_connections) {
            const conn = try self.allocator.create(Connection);
            conn.* = Connection.init(self.allocator);
            try conn.connect(self.connection_string);
            try self.connections.append(self.allocator, conn);
            return conn;
        }

        return PostgresError.PoolExhausted;
    }

    pub fn release(self: *@This(), conn: *Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.available.append(self.allocator, conn) catch {};
    }
};

pub const Connection = struct {
    pq: ?*libpq.PGconn,
    last_result: ?*libpq.PGresult,
    is_reading: bool,
    is_reffed: bool,
    result_buffer: std.StringArrayHashMap(PgType),
    allocator: std.mem.Allocator,
    format_buffer: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024), //16KB buffer
    prepared_statements: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) Connection {
        return .{
            .pq = null,
            .last_result = null,
            .is_reading = false,
            .is_reffed = false,
            .result_buffer = std.StringArrayHashMap(PgType).init(allocator),
            .allocator = allocator,
            .prepared_statements = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.result_buffer.deinit();
        self.prepared_statements.deinit();
        if (self.last_result != null) {
            libpq.PQclear(self.last_result);
        }
        if (self.pq != null) {
            libpq.PQfinish(self.pq);
            self.pq = null;
        }
    }

    pub fn connect(self: *@This(), connString: []const u8) !void {
        std.log.info("DB Connection parameters: {s}\n", .{connString});
        self.pq = libpq.PQconnectdb(@ptrCast(connString));
        const conn_status = libpq.PQstatus(self.pq);

        if (conn_status != libpq.CONNECTION_OK) {
            std.log.err("Connection failed: {s}\n", .{libpq.PQerrorMessage(self.pq)});
            return PostgresError.ConnectionFailed;
        }

        std.log.info("DB Connection success\n", .{});
    }

    pub fn connectWithSSL(self: *@This(), connString: []const u8, ssl_config: SSLConfig) !void {
        var full_conn_string = try std.fmt.allocPrint(self.allocator, "{s} sslmode={s}", .{ connString, @tagName(ssl_config.mode) });
        defer self.allocator.free(full_conn_string);

        if (ssl_config.cert_file) |cert| {
            const temp = full_conn_string;
            full_conn_string = try std.fmt.allocPrint(self.allocator, "{s} sslcert={s}", .{ temp, cert });
            self.allocator.free(temp);
        }

        if (ssl_config.key_file) |key| {
            const temp = full_conn_string;
            full_conn_string = try std.fmt.allocPrint(self.allocator, "{s} sslkey={s}", .{ temp, key });
            self.allocator.free(temp);
        }

        if (ssl_config.ca_file) |ca| {
            const temp = full_conn_string;
            full_conn_string = try std.fmt.allocPrint(self.allocator, "{s} sslrootcert={s}", .{ temp, ca });
            self.allocator.free(temp);
        }

        try self.connect(full_conn_string);
    }

    pub fn exec(self: *@This(), comptime query: []const u8, argv: anytype) !void {
        if (self.pq == null) return PostgresError.ConnectionFailed;

        @memset(self.format_buffer[0..], 0);
        const m_query = try std.fmt.bufPrint(&self.format_buffer, query, argv);

        const result = libpq.PQexec(self.pq, @ptrCast(m_query));
        if (result == null) {
            std.log.err("Exec failed: {s}\n", .{libpq.PQerrorMessage(self.pq)});
            return PostgresError.QueryFailed;
        }
        self.last_result = result;
    }

    pub fn execSafe(self: *@This(), query: []const u8) !ResultSet {
        if (self.pq == null) return PostgresError.ConnectionFailed;

        const result = libpq.PQexec(self.pq, @ptrCast(query));
        if (result == null) {
            std.log.err("Exec failed: {s}\n", .{libpq.PQerrorMessage(self.pq)});
            return PostgresError.QueryFailed;
        }

        const status = libpq.PQresultStatus(result);
        if (status != libpq.PGRES_TUPLES_OK and status != libpq.PGRES_COMMAND_OK) {
            const err = libpq.PQresultErrorMessage(result);
            std.log.err("Query failed: {s}\n", .{err});
            libpq.PQclear(result);
            return PostgresError.QueryFailed;
        }

        return ResultSet.init(result.?, self.allocator);
    }

    // Prepared statements
    pub fn prepare(self: *@This(), name: []const u8, query: []const u8, param_types: []const u32) !void {
        if (self.pq == null) return PostgresError.ConnectionFailed;

        const result = libpq.PQprepare(self.pq, name.ptr, query.ptr, @intCast(param_types.len), if (param_types.len > 0) param_types.ptr else null);

        if (result == null) {
            return PostgresError.PreparedStatementFailed;
        }

        const status = libpq.PQresultStatus(result);
        libpq.PQclear(result);

        if (status != libpq.PGRES_COMMAND_OK) {
            return PostgresError.PreparedStatementFailed;
        }

        try self.prepared_statements.put(try self.allocator.dupe(u8, name), {});
    }

    pub fn execPrepared(self: *@This(), stmt_name: []const u8, params: []const ?[]const u8) !ResultSet {
        if (self.pq == null) return PostgresError.ConnectionFailed;

        // Convert params to the format libpq expects
        var param_values: [][*c]const u8 = undefined;
        if (params.len > 0) {
            param_values = try self.allocator.alloc([*c]const u8, params.len);
            defer self.allocator.free(param_values);

            for (params, 0..) |param, i| {
                param_values[i] = if (param) |p| p.ptr else null;
            }
        }

        const result = libpq.PQexecPrepared(self.pq, stmt_name.ptr, @intCast(params.len), if (params.len > 0) param_values.ptr else null, null, // param lengths (null for text format)
            null, // param formats (null for text format)
            0 // result format (0 for text)
        );

        if (result == null) {
            return PostgresError.QueryFailed;
        }

        const status = libpq.PQresultStatus(result);
        if (status != libpq.PGRES_TUPLES_OK and status != libpq.PGRES_COMMAND_OK) {
            const err = libpq.PQresultErrorMessage(result);
            std.log.err("Prepared query failed: {s}\n", .{err});
            libpq.PQclear(result);
            return PostgresError.QueryFailed;
        }

        return ResultSet.init(result.?, self.allocator);
    }

    // Transaction management
    pub fn beginTransaction(self: *@This()) !void {
        try self.exec("BEGIN", .{});
        const status = libpq.PQresultStatus(self.last_result);
        if (status != libpq.PGRES_COMMAND_OK) {
            return PostgresError.TransactionBeginFailed;
        }
    }

    pub fn commit(self: *@This()) !void {
        try self.exec("COMMIT", .{});
        const status = libpq.PQresultStatus(self.last_result);
        if (status != libpq.PGRES_COMMAND_OK) {
            return PostgresError.TransactionCommitFailed;
        }
    }

    pub fn rollback(self: *@This()) !void {
        try self.exec("ROLLBACK", .{});
        const status = libpq.PQresultStatus(self.last_result);
        if (status != libpq.PGRES_COMMAND_OK) {
            return PostgresError.TransactionRollbackFailed;
        }
    }

    pub fn savepoint(self: *@This(), name: []const u8) !void {
        try self.exec("SAVEPOINT {s}", .{name});
        const status = libpq.PQresultStatus(self.last_result);
        if (status != libpq.PGRES_COMMAND_OK) {
            return PostgresError.QueryFailed;
        }
    }

    pub fn rollbackToSavepoint(self: *@This(), name: []const u8) !void {
        try self.exec("ROLLBACK TO SAVEPOINT {s}", .{name});
        const status = libpq.PQresultStatus(self.last_result);
        if (status != libpq.PGRES_COMMAND_OK) {
            return PostgresError.QueryFailed;
        }
    }

    // Async operations
    pub fn execAsync(self: *@This(), query: []const u8) !void {
        if (self.pq == null) return PostgresError.ConnectionFailed;

        const result = libpq.PQsendQuery(self.pq, query.ptr);
        if (result != 1) {
            return PostgresError.QueryFailed;
        }
    }

    pub fn getResult(self: *@This()) !?*libpq.PGresult {
        if (self.pq == null) return PostgresError.ConnectionFailed;
        return libpq.PQgetResult(self.pq);
    }

    pub fn isNonBlocking(self: *@This()) bool {
        if (self.pq == null) return false;
        return libpq.PQisnonblocking(self.pq) == 1;
    }

    pub fn setNonBlocking(self: *@This(), non_blocking: bool) !void {
        if (self.pq == null) return PostgresError.ConnectionFailed;

        const result = libpq.PQsetnonblocking(self.pq, if (non_blocking) 1 else 0);
        if (result != 0) {
            return PostgresError.QueryFailed;
        }
    }

    // Connection health
    pub fn ping(self: *@This()) bool {
        if (self.pq == null) return false;
        return libpq.PQstatus(self.pq) == libpq.CONNECTION_OK;
    }

    pub fn reconnect(self: *@This()) !void {
        if (self.pq != null) {
            libpq.PQreset(self.pq);
            if (libpq.PQstatus(self.pq) == libpq.CONNECTION_OK) {
                return;
            }
        }
        return PostgresError.ConnectionFailed;
    }

    // Enhanced error handling
    pub fn getDetailedError(self: *@This()) PostgresErrorInfo {
        if (self.last_result == null) return PostgresErrorInfo{
            .message = "No result available",
            .sqlstate = "",
            .severity = "",
            .detail = "",
            .hint = "",
        };

        // Helper function to safely convert C strings with fallback
        const getErrorField = struct {
            fn call(ptr: ?[*c]u8, fallback: []const u8) []const u8 {
                if (ptr) |p| {
                    return std.mem.span(p);
                } else {
                    return fallback;
                }
            }
        }.call;

        return PostgresErrorInfo{
            .message = getErrorField(libpq.PQresultErrorMessage(self.last_result), "Unknown error"),
            .sqlstate = getErrorField(libpq.PQresultErrorField(self.last_result, libpq.PG_DIAG_SQLSTATE), ""),
            .severity = getErrorField(libpq.PQresultErrorField(self.last_result, libpq.PG_DIAG_SEVERITY), ""),
            .detail = getErrorField(libpq.PQresultErrorField(self.last_result, libpq.PG_DIAG_MESSAGE_DETAIL), ""),
            .hint = getErrorField(libpq.PQresultErrorField(self.last_result, libpq.PG_DIAG_MESSAGE_HINT), ""),
        };
    }

    // Bulk operations
    pub fn copyFrom(self: *@This(), table: []const u8, columns: []const []const u8, data: []const []const []const u8) !void {
        if (self.pq == null) return PostgresError.ConnectionFailed;

        const column_list = try std.mem.join(self.allocator, ",", columns);
        defer self.allocator.free(column_list);

        const copy_query = try std.fmt.allocPrint(self.allocator, "COPY {s} ({s}) FROM STDIN WITH CSV", .{ table, column_list });
        defer self.allocator.free(copy_query);

        const result = libpq.PQexec(self.pq, copy_query.ptr);
        if (result == null or libpq.PQresultStatus(result) != libpq.PGRES_COPY_IN) {
            if (result != null) libpq.PQclear(result);
            return PostgresError.QueryFailed;
        }
        libpq.PQclear(result);

        // Send data
        for (data) |row| {
            const row_data = try std.mem.join(self.allocator, ",", row);
            defer self.allocator.free(row_data);

            const line = try std.fmt.allocPrint(self.allocator, "{s}\n", .{row_data});
            defer self.allocator.free(line);

            if (libpq.PQputCopyData(self.pq, line.ptr, @intCast(line.len)) != 1) {
                _ = libpq.PQputCopyEnd(self.pq, "Error during COPY");
                return PostgresError.QueryFailed;
            }
        }

        // End copy
        if (libpq.PQputCopyEnd(self.pq, null) != 1) {
            return PostgresError.QueryFailed;
        }

        // Get final result
        const final_result = libpq.PQgetResult(self.pq);
        if (final_result == null or libpq.PQresultStatus(final_result) != libpq.PGRES_COMMAND_OK) {
            if (final_result != null) libpq.PQclear(final_result);
            return PostgresError.QueryFailed;
        }
        libpq.PQclear(final_result);
    }

    pub fn getLastResult(self: *@This()) !std.StringArrayHashMap(PgType).Iterator {
        const stat = libpq.PQresultStatus(self.last_result);

        switch (stat) {
            libpq.PGRES_COMMAND_OK => return self.result_buffer.iterator(),
            libpq.PGRES_TUPLES_OK => {
                const nrows: usize = @intCast(libpq.PQntuples(self.last_result));
                const ncols: usize = @intCast(libpq.PQnfields(self.last_result));

                // Clear the result buffer to store fresh data
                self.result_buffer.clearAndFree();

                for (0..nrows) |i| for (0..ncols) |j| {
                    const field_name = std.mem.span(libpq.PQfname(self.last_result, @intCast(j)));
                    const value = std.mem.span(libpq.PQgetvalue(self.last_result, @intCast(i), @intCast(j)));

                    const field_type = libpq.PQftype(self.last_result, @intCast(j));
                    var pg_value: PgType = undefined;

                    std.debug.print("OID: {}\n", .{field_type});

                    pg_value = switch (field_type) {
                        16 => PgType{ .boolean = std.mem.eql(u8, value, "t") }, // bool
                        20 => PgType{ .bigint = std.fmt.parseInt(i64, value, 10) catch 0 }, // int8
                        21 => PgType{ .smallint = std.fmt.parseInt(i16, value, 10) catch 0 }, // int2
                        23 => PgType{ .integer = std.fmt.parseInt(i32, value, 10) catch 0 }, // int4
                        700 => PgType{ .real = std.fmt.parseFloat(f32, value) catch 0.0 }, // float4
                        701 => PgType{ .double = std.fmt.parseFloat(f64, value) catch 0.0 }, // float8
                        1042, 1043 => PgType{ .varchar = value }, // char, varchar
                        25 => PgType{ .text = value }, // text
                        114, 3802 => PgType{ .json = value }, // json, jsonb
                        17 => PgType{ .bytea = value }, // bytea
                        2950 => blk: { // uuid
                            const uuid_bytes: [16]u8 = [_]u8{0} ** 16;
                            // TODO: Parse UUID string to bytes properly
                            break :blk PgType{ .uuid = uuid_bytes };
                        },
                        1700 => PgType{ .numeric = value }, // numeric
                        // Legacy support
                        20...23 => PgType{ .number = std.fmt.parseInt(i64, value, 10) catch {
                            std.debug.print("Error parsing number for column {s}\n", .{field_name});
                            continue;
                        } },
                        else => PgType{ .string = value },
                    };

                    self.result_buffer.put(field_name[0..], pg_value) catch {
                        return PostgresError.BufferInsertFailed;
                    };
                };

                std.debug.print("Rows: {}, Columns: {}\n", .{ nrows, ncols });
                return self.result_buffer.iterator();
            },
            else => {
                const err = libpq.PQresultErrorMessage(self.last_result);
                std.debug.print("Query Fatal Error: {s}\n", .{err});
                return PostgresError.QueryFailed;
            },
        }
    }

    pub fn getLastErrorMessage(self: *@This()) ?[]const u8 {
        if (self.pq != null) {
            return std.mem.span(libpq.PQerrorMessage(self.pq));
        }
        return null;
    }

    pub fn serverVersion(self: *@This()) i32 {
        return libpq.PQserverVersion(self.pq);
    }

    pub fn clientVersion(self: *@This()) i32 {
        _ = self;
        return libpq.PQlibVersion();
    }

    pub fn escapeLiteral(self: *@This(), str: []const u8) ![]u8 {
        if (self.pq == null) return PostgresError.ConnectionFailed;

        const escaped = libpq.PQescapeLiteral(self.pq, str.ptr, str.len);
        if (escaped == null) {
            return PostgresError.QueryFailed;
        }
        defer libpq.PQfreemem(escaped);

        return self.allocator.dupe(u8, std.mem.span(escaped));
    }

    pub fn escapeIdentifier(self: *@This(), str: []const u8) ![]u8 {
        if (self.pq == null) return PostgresError.ConnectionFailed;

        const escaped = libpq.PQescapeIdentifier(self.pq, str.ptr, str.len);
        if (escaped == null) {
            return PostgresError.QueryFailed;
        }
        defer libpq.PQfreemem(escaped);

        return self.allocator.dupe(u8, std.mem.span(escaped));
    }
};

// Utility functions for working with PostgreSQL
pub fn createConnectionString(allocator: std.mem.Allocator, host: []const u8, port: u16, database: []const u8, username: []const u8, password: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "host={s} port={d} dbname={s} user={s} password={s}", .{ host, port, database, username, password });
}

pub fn parseUUID(uuid_str: []const u8) ![16]u8 {
    if (uuid_str.len != 36) return PostgresError.TypeMismatch;

    var uuid_bytes: [16]u8 = undefined;
    var byte_index: usize = 0;
    var i: usize = 0;

    while (i < uuid_str.len and byte_index < 16) : (i += 1) {
        if (uuid_str[i] == '-') continue;

        if (i + 1 >= uuid_str.len) return PostgresError.TypeMismatch;

        const hex_byte = std.fmt.parseInt(u8, uuid_str[i .. i + 2], 16) catch return PostgresError.TypeMismatch;
        uuid_bytes[byte_index] = hex_byte;
        byte_index += 1;
        i += 1; // Skip the second hex character
    }

    return uuid_bytes;
}

pub fn formatUUID(uuid_bytes: [16]u8, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ uuid_bytes[0], uuid_bytes[1], uuid_bytes[2], uuid_bytes[3], uuid_bytes[4], uuid_bytes[5], uuid_bytes[6], uuid_bytes[7], uuid_bytes[8], uuid_bytes[9], uuid_bytes[10], uuid_bytes[11], uuid_bytes[12], uuid_bytes[13], uuid_bytes[14], uuid_bytes[15] });
}

// Database migration utilities
pub const Migration = struct {
    version: u32,
    name: []const u8,
    up_sql: []const u8,
    down_sql: []const u8,
};

pub const MigrationRunner = struct {
    connection: *Connection,
    allocator: std.mem.Allocator,

    pub fn init(connection: *Connection, allocator: std.mem.Allocator) MigrationRunner {
        return MigrationRunner{
            .connection = connection,
            .allocator = allocator,
        };
    }

    pub fn ensureMigrationTable(self: *@This()) !void {
        const create_table_sql =
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\    version INTEGER PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    applied_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
            \\)
        ;

        _ = try self.connection.execSafe(create_table_sql);
    }

    pub fn applyMigration(self: *@This(), migration: Migration) !void {
        try self.connection.beginTransaction();
        errdefer self.connection.rollback() catch {};

        // Check if migration already applied
        const check_sql = "SELECT version FROM schema_migrations WHERE version = $1";
        try self.connection.prepare("check_migration", check_sql, &[_]u32{23}); // int4

        const version_str = try std.fmt.allocPrint(self.allocator, "{d}", .{migration.version});
        defer self.allocator.free(version_str);

        var result = try self.connection.execPrepared("check_migration", &[_]?[]const u8{version_str});
        if (result.rowCount() > 0) {
            try self.connection.rollback();
            std.log.info("Migration {d} already applied\n", .{migration.version});
            return;
        }

        // Apply migration
        _ = try self.connection.execSafe(migration.up_sql);

        // Record migration
        const insert_sql = "INSERT INTO schema_migrations (version, name) VALUES ($1, $2)";
        try self.connection.prepare("insert_migration", insert_sql, &[_]u32{ 23, 25 }); // int4, text
        _ = try self.connection.execPrepared("insert_migration", &[_]?[]const u8{ version_str, migration.name });

        try self.connection.commit();
        std.log.info("Applied migration {d}: {s}\n", .{ migration.version, migration.name });
    }

    pub fn rollbackMigration(self: *@This(), migration: Migration) !void {
        try self.connection.beginTransaction();
        errdefer self.connection.rollback() catch {};

        // Apply rollback
        _ = try self.connection.execSafe(migration.down_sql);

        // Remove migration record
        const delete_sql = "DELETE FROM schema_migrations WHERE version = $1";
        try self.connection.prepare("delete_migration", delete_sql, &[_]u32{23}); // int4

        const version_str = try std.fmt.allocPrint(self.allocator, "{d}", .{migration.version});
        defer self.allocator.free(version_str);

        _ = try self.connection.execPrepared("delete_migration", &[_]?[]const u8{version_str});

        try self.connection.commit();
        std.log.info("Rolled back migration {d}: {s}\n", .{ migration.version, migration.name });
    }
};

// Connection monitoring and metrics
pub const ConnectionMetrics = struct {
    total_queries: u64,
    successful_queries: u64,
    failed_queries: u64,
    total_connection_time: u64, // milliseconds
    last_activity: i64, // timestamp

    pub fn init() ConnectionMetrics {
        return ConnectionMetrics{
            .total_queries = 0,
            .successful_queries = 0,
            .failed_queries = 0,
            .total_connection_time = 0,
            .last_activity = std.time.timestamp(),
        };
    }

    pub fn recordQuery(self: *@This(), success: bool, duration_ms: u64) void {
        self.total_queries += 1;
        if (success) {
            self.successful_queries += 1;
        } else {
            self.failed_queries += 1;
        }
        self.total_connection_time += duration_ms;
        self.last_activity = std.time.timestamp();
    }

    pub fn getSuccessRate(self: *@This()) f64 {
        if (self.total_queries == 0) return 0.0;
        return @as(f64, @floatFromInt(self.successful_queries)) / @as(f64, @floatFromInt(self.total_queries));
    }

    pub fn getAverageQueryTime(self: *@This()) f64 {
        if (self.total_queries == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_connection_time)) / @as(f64, @floatFromInt(self.total_queries));
    }
};

test "simple libpq connection" {
    const db_host = get_db_host_env();
    const connection_string = std.fmt.allocPrint(std.testing.allocator, "postgresql://postgres:postgres@{s}:5432", .{db_host}) catch "postgresql://postgres:postgres@localhost:5432";
    defer std.testing.allocator.free(connection_string);

    const conn = libpq.PQconnectdb(connection_string.ptr);
    defer libpq.PQfinish(conn);

    if (libpq.PQstatus(conn) != libpq.CONNECTION_OK) {
        std.debug.print("Error: {s} \n", .{libpq.PQerrorMessage(conn)});
        return;
    }

    std.debug.print("Connected to the server\n", .{});
}

test "libpq wrapper API" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var conn = Connection.init(allocator);
    defer conn.deinit();

    const db_host = get_db_host_env();
    const connection_string = std.fmt.allocPrint(allocator, "postgresql://postgres:postgres@{s}:5432", .{db_host}) catch "postgresql://postgres:postgres@localhost:5432";
    defer allocator.free(connection_string);

    try conn.connect(connection_string);

    std.debug.print("PSQL Server version: {} \n", .{conn.serverVersion()});
}

test "connection string creation" {
    const allocator = std.testing.allocator;

    const conn_str = try createConnectionString(allocator, "localhost", 5432, "testdb", "testuser", "testpass");
    defer allocator.free(conn_str);

    const expected = "host=localhost port=5432 dbname=testdb user=testuser password=testpass";
    try std.testing.expectEqualStrings(expected, conn_str);
}

test "UUID parsing and formatting" {
    const allocator = std.testing.allocator;

    // Test UUID parsing
    const uuid_str = "550e8400-e29b-41d4-a716-446655440000";
    const uuid_bytes = try parseUUID(uuid_str);

    // Test UUID formatting
    const formatted = try formatUUID(uuid_bytes, allocator);
    defer allocator.free(formatted);

    try std.testing.expectEqualStrings(uuid_str, formatted);
}

test "UUID parsing errors" {
    // Test invalid UUID length
    try std.testing.expectError(PostgresError.TypeMismatch, parseUUID("invalid"));

    // Test invalid hex characters
    try std.testing.expectError(PostgresError.TypeMismatch, parseUUID("gggggggg-gggg-gggg-gggg-gggggggggggg"));
}

test "PgType value parsing" {
    // Test integer parsing
    try std.testing.expectEqual(@as(i32, 42), try parseValue(i32, "42"));
    try std.testing.expectEqual(@as(i64, -123), try parseValue(i64, "-123"));
    try std.testing.expectEqual(@as(i16, 999), try parseValue(i16, "999"));

    // Test float parsing
    try std.testing.expectEqual(@as(f32, 3.14), try parseValue(f32, "3.14"));
    try std.testing.expectEqual(@as(f64, -2.71), try parseValue(f64, "-2.71"));

    // Test boolean parsing
    try std.testing.expectEqual(true, try parseValue(bool, "t"));
    try std.testing.expectEqual(true, try parseValue(bool, "true"));
    try std.testing.expectEqual(false, try parseValue(bool, "f"));
    try std.testing.expectEqual(false, try parseValue(bool, "false"));

    // Test string parsing
    try std.testing.expectEqualStrings("hello", try parseValue([]const u8, "hello"));
}

test "value to string conversion" {
    const allocator = std.testing.allocator;

    // Test integer conversion
    {
        const result = try valueToString(allocator, @as(i32, 42));
        defer allocator.free(result);
        try std.testing.expectEqualStrings("42", result);
    }

    // Test float conversion
    {
        const result = try valueToString(allocator, @as(f32, 3.14));
        defer allocator.free(result);
        try std.testing.expectEqualStrings("3.14", result);
    }

    // Test boolean conversion
    {
        const result_true = try valueToString(allocator, true);
        defer allocator.free(result_true);
        try std.testing.expectEqualStrings("true", result_true);

        const result_false = try valueToString(allocator, false);
        defer allocator.free(result_false);
        try std.testing.expectEqualStrings("false", result_false);
    }

    // Test slice string conversion
    {
        const result = try valueToString(allocator, @as([]const u8, "hello world"));
        defer allocator.free(result);
        try std.testing.expectEqualStrings("hello world", result);
    }

    // Test comptime string literal (array) conversion
    {
        const comptime_str = "hello";
        const result = try valueToString(allocator, comptime_str);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("hello", result);
    }

    // Test null-terminated array conversion
    {
        const null_term_array: [6:0]u8 = "hello\x00".*;
        const result = try valueToString(allocator, null_term_array);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("hello", result);
    }

    // Test pointer to null-terminated array
    {
        const str = "hello";
        const ptr: *const [5:0]u8 = str;
        const result = try valueToString(allocator, ptr);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("hello", result);
    }

    // Test null-terminated pointer
    {
        const str = "hello";
        const ptr: [*:0]const u8 = str.ptr;
        const result = try valueToString(allocator, ptr);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("hello", result);
    }

    // Test C pointer
    {
        const str = "hello";
        const c_ptr: [*c]const u8 = str.ptr;
        const result = try valueToString(allocator, c_ptr);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("hello", result);
    }

    // Test optional values
    {
        const opt_val: ?i32 = 42;
        const result = try valueToString(allocator, opt_val);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("42", result);

        const null_val: ?i32 = null;
        const result_null = try valueToString(allocator, null_val);
        defer allocator.free(result_null);
        try std.testing.expectEqualStrings("null", result_null);
    }
}

test "query builder" {
    const allocator = std.testing.allocator;

    var builder = QueryBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.sql("SELECT name, age FROM users WHERE age > ");
    _ = try builder.bind(@as(i32, 18));
    _ = try builder.sql(" AND active = ");
    _ = try builder.bind(true);
    _ = try builder.sql(" AND city = ");
    _ = try builder.bind("New York");

    const query = builder.build();
    try std.testing.expectEqualStrings("SELECT name, age FROM users WHERE age > $1 AND active = $2 AND city = $3", query);

    // Check that parameters are correctly stored
    try std.testing.expectEqual(@as(usize, 3), builder.params.items.len);
    try std.testing.expectEqualStrings("18", builder.params.items[0]);
    try std.testing.expectEqualStrings("true", builder.params.items[1]);
    try std.testing.expectEqualStrings("New York", builder.params.items[2]);
}

test "connection metrics" {
    var metrics = ConnectionMetrics.init();

    // Initially should have no queries
    try std.testing.expectEqual(@as(u64, 0), metrics.total_queries);
    try std.testing.expectEqual(@as(f64, 0.0), metrics.getSuccessRate());
    try std.testing.expectEqual(@as(f64, 0.0), metrics.getAverageQueryTime());

    // Record some successful queries
    metrics.recordQuery(true, 100);
    metrics.recordQuery(true, 200);
    metrics.recordQuery(false, 50);

    try std.testing.expectEqual(@as(u64, 3), metrics.total_queries);
    try std.testing.expectEqual(@as(u64, 2), metrics.successful_queries);
    try std.testing.expectEqual(@as(u64, 1), metrics.failed_queries);

    // Success rate should be 2/3
    const success_rate = metrics.getSuccessRate();
    try std.testing.expect(success_rate > 0.66 and success_rate < 0.67);

    // Average query time should be (100 + 200 + 50) / 3
    const avg_time = metrics.getAverageQueryTime();
    try std.testing.expect(avg_time > 116.6 and avg_time < 116.7);
}

test "date and time structures" {
    const date = Date{ .year = 2023, .month = 12, .day = 25 };
    try std.testing.expectEqual(@as(i32, 2023), date.year);
    try std.testing.expectEqual(@as(u8, 12), date.month);
    try std.testing.expectEqual(@as(u8, 25), date.day);

    const time = Time{ .hour = 14, .minute = 30, .second = 45, .microsecond = 123456 };
    try std.testing.expectEqual(@as(u8, 14), time.hour);
    try std.testing.expectEqual(@as(u8, 30), time.minute);
    try std.testing.expectEqual(@as(u8, 45), time.second);
    try std.testing.expectEqual(@as(u32, 123456), time.microsecond);

    const datetime = DateTime{ .date = date, .time = time };
    try std.testing.expectEqual(date.year, datetime.date.year);
    try std.testing.expectEqual(time.hour, datetime.time.hour);

    const datetime_tz = DateTimeTz{ .datetime = datetime, .timezone_offset = -18000 }; // EST offset
    try std.testing.expectEqual(@as(i32, -18000), datetime_tz.timezone_offset);
}

test "PgType union variants" {
    // Test numeric types
    const smallint_val = PgType{ .smallint = 42 };
    const integer_val = PgType{ .integer = 12345 };
    // const bigint_val = PgType{ .bigint = 9876543210 };
    // const real_val = PgType{ .real = 3.14 };
    // const double_val = PgType{ .double = 2.718281828 };

    switch (smallint_val) {
        .smallint => |val| try std.testing.expectEqual(@as(i16, 42), val),
        else => try std.testing.expect(false),
    }

    switch (integer_val) {
        .integer => |val| try std.testing.expectEqual(@as(i32, 12345), val),
        else => try std.testing.expect(false),
    }

    // Test text types
    const varchar_val = PgType{ .varchar = "hello" };
    // const text_val = PgType{ .text = "world" };

    switch (varchar_val) {
        .varchar => |val| try std.testing.expectEqualStrings("hello", val),
        else => try std.testing.expect(false),
    }

    // Test boolean type
    const bool_val = PgType{ .boolean = true };
    switch (bool_val) {
        .boolean => |val| try std.testing.expectEqual(true, val),
        else => try std.testing.expect(false),
    }

    // Test null type
    const null_val = PgType{ .null = {} };
    switch (null_val) {
        .null => {},
        else => try std.testing.expect(false),
    }
}

test "SSL configuration" {
    const ssl_config = SSLConfig{
        .mode = .require,
        .cert_file = "client.crt",
        .key_file = "client.key",
        .ca_file = "ca.crt",
    };

    try std.testing.expectEqual(@as(@TypeOf(ssl_config.mode), .require), ssl_config.mode);
    try std.testing.expectEqualStrings("client.crt", ssl_config.cert_file.?);
    try std.testing.expectEqualStrings("client.key", ssl_config.key_file.?);
    try std.testing.expectEqualStrings("ca.crt", ssl_config.ca_file.?);
}

test "migration structure" {
    const migration = Migration{
        .version = 1,
        .name = "create_users_table",
        .up_sql = "CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT);",
        .down_sql = "DROP TABLE users;",
    };

    try std.testing.expectEqual(@as(u32, 1), migration.version);
    try std.testing.expectEqualStrings("create_users_table", migration.name);
    try std.testing.expectEqualStrings("CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT);", migration.up_sql);
    try std.testing.expectEqualStrings("DROP TABLE users;", migration.down_sql);
}

// Integration tests (require a running PostgreSQL instance)
test "full database integration" {
    if (try std.process.hasEnvVar(std.testing.allocator, "SKIP_INTEGRATION_TESTS")) {
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var conn = Connection.init(allocator);
    defer conn.deinit();

    const db_host = get_db_host_env();
    const connection_string = std.fmt.allocPrint(allocator, "postgresql://postgres:postgres@{s}:5432", .{db_host}) catch "postgresql://postgres:postgres@localhost:5432";
    defer allocator.free(connection_string);

    try conn.connect(connection_string);

    // Test basic query execution
    try conn.exec("DROP TABLE IF EXISTS test_users", .{});
    try conn.exec("CREATE TABLE test_users (id SERIAL PRIMARY KEY, name TEXT, age INTEGER, active BOOLEAN)", .{});

    // Test insert operations
    try conn.exec("INSERT INTO test_users (name, age, active) VALUES ('Alice', 25, true)", .{});
    try conn.exec("INSERT INTO test_users (name, age, active) VALUES ('Bob', 30, false)", .{});

    // Test select with ResultSet
    var result = try conn.execSafe("SELECT id, name, age, active FROM test_users ORDER BY id");
    try std.testing.expectEqual(@as(i32, 2), result.rowCount());
    try std.testing.expectEqual(@as(i32, 4), result.columnCount());

    // Test row iteration
    var row_count: i32 = 0;
    while (result.next()) |*row| {
        row_count += 1;
        const id = try row.get("id", i32);
        const name = try row.get("name", []const u8);
        const age = try row.get("age", i32);
        const active = try row.get("active", bool);

        if (row_count == 1) {
            try std.testing.expectEqual(@as(i32, 1), id);
            try std.testing.expectEqualStrings("Alice", name);
            try std.testing.expectEqual(@as(i32, 25), age);
            try std.testing.expectEqual(true, active);
        } else if (row_count == 2) {
            try std.testing.expectEqual(@as(i32, 2), id);
            try std.testing.expectEqualStrings("Bob", name);
            try std.testing.expectEqual(@as(i32, 30), age);
            try std.testing.expectEqual(false, active);
        }
    }
    try std.testing.expectEqual(@as(i32, 2), row_count);

    // Clean up
    try conn.exec("DROP TABLE test_users", .{});
}

test "prepared statements integration" {
    if (try std.process.hasEnvVar(std.testing.allocator, "SKIP_INTEGRATION_TESTS")) {
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var conn = Connection.init(allocator);
    defer conn.deinit();

    const db_host = get_db_host_env();
    const connection_string = std.fmt.allocPrint(allocator, "postgresql://postgres:postgres@{s}:5432", .{db_host}) catch "postgresql://postgres:postgres@localhost:5432";
    defer allocator.free(connection_string);

    try conn.connect(connection_string);

    // Setup test table
    try conn.exec("DROP TABLE IF EXISTS test_prep", .{});
    try conn.exec("CREATE TABLE test_prep (id SERIAL PRIMARY KEY, name TEXT, value INTEGER)", .{});

    // Test prepared insert
    try conn.prepare("insert_test", "INSERT INTO test_prep (name, value) VALUES ($1, $2)", &[_]u32{ 25, 23 }); // text, int4

    _ = try conn.execPrepared("insert_test", &[_]?[]const u8{ "test1", "100" });
    _ = try conn.execPrepared("insert_test", &[_]?[]const u8{ "test2", "200" });

    // Test prepared select
    try conn.prepare("select_by_name", "SELECT id, name, value FROM test_prep WHERE name = $1", &[_]u32{25}); // text

    var result = try conn.execPrepared("select_by_name", &[_]?[]const u8{"test1"});
    try std.testing.expectEqual(@as(i32, 1), result.rowCount());

    if (result.next()) |row| {
        const name = try row.get("name", []const u8);
        const value = try row.get("value", i32);
        try std.testing.expectEqualStrings("test1", name);
        try std.testing.expectEqual(@as(i32, 100), value);
    }

    // Clean up
    try conn.exec("DROP TABLE test_prep", .{});
}

test "transaction management integration" {
    if (try std.process.hasEnvVar(std.testing.allocator, "SKIP_INTEGRATION_TESTS")) {
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var conn = Connection.init(allocator);
    defer conn.deinit();

    const db_host = get_db_host_env();
    const connection_string = std.fmt.allocPrint(allocator, "postgresql://postgres:postgres@{s}:5432", .{db_host}) catch "postgresql://postgres:postgres@localhost:5432";
    defer allocator.free(connection_string);

    try conn.connect(connection_string);

    // Setup test table
    try conn.exec("DROP TABLE IF EXISTS test_txn", .{});
    try conn.exec("CREATE TABLE test_txn (id SERIAL PRIMARY KEY, value INTEGER)", .{});

    // Test successful transaction
    try conn.beginTransaction();
    try conn.exec("INSERT INTO test_txn (value) VALUES (1)", .{});
    try conn.exec("INSERT INTO test_txn (value) VALUES (2)", .{});
    try conn.commit();

    var result = try conn.execSafe("SELECT COUNT(*) as count FROM test_txn");
    if (result.next()) |row| {
        const count = try row.get("count", i64);
        try std.testing.expectEqual(@as(i64, 2), count);
    }

    // Test rollback
    try conn.beginTransaction();
    try conn.exec("INSERT INTO test_txn (value) VALUES (3)", .{});
    try conn.exec("INSERT INTO test_txn (value) VALUES (4)", .{});
    try conn.rollback();

    result = try conn.execSafe("SELECT COUNT(*) as count FROM test_txn");
    if (result.next()) |row| {
        const count = try row.get("count", i64);
        try std.testing.expectEqual(@as(i64, 2), count); // Should still be 2
    }

    // Test savepoints
    try conn.beginTransaction();
    try conn.exec("INSERT INTO test_txn (value) VALUES (5)", .{});
    try conn.savepoint("sp1");
    try conn.exec("INSERT INTO test_txn (value) VALUES (6)", .{});
    try conn.rollbackToSavepoint("sp1");
    try conn.commit();

    result = try conn.execSafe("SELECT COUNT(*) as count FROM test_txn");
    if (result.next()) |row| {
        const count = try row.get("count", i64);
        try std.testing.expectEqual(@as(i64, 3), count); // Should be 3 (original 2 + 1 from savepoint test)
    }

    // Clean up
    try conn.exec("DROP TABLE test_txn", .{});
}

test "connection pool integration" {
    if (try std.process.hasEnvVar(std.testing.allocator, "SKIP_INTEGRATION_TESTS")) {
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const db_host = get_db_host_env();
    const connection_string = std.fmt.allocPrint(allocator, "postgresql://postgres:postgres@{s}:5432", .{db_host}) catch "postgresql://postgres:postgres@localhost:5432";
    defer allocator.free(connection_string);

    var pool = try ConnectionPool.init(allocator, connection_string, 2, 5);
    defer pool.deinit();

    // Test acquiring connections
    const conn1 = try pool.acquire();
    const conn2 = try pool.acquire();

    // Test that connections work
    try conn1.exec("SELECT 1", .{});
    try conn2.exec("SELECT 2", .{});

    // Test connection health
    try std.testing.expect(conn1.ping());
    try std.testing.expect(conn2.ping());

    // Return connections to pool
    pool.release(conn1);
    pool.release(conn2);

    // Test acquiring again (should reuse connections)
    const conn3 = try pool.acquire();
    const conn4 = try pool.acquire();

    try std.testing.expect(conn3.ping());
    try std.testing.expect(conn4.ping());

    pool.release(conn3);
    pool.release(conn4);
}

test "migration system integration" {
    if (try std.process.hasEnvVar(std.testing.allocator, "SKIP_INTEGRATION_TESTS")) {
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var conn = Connection.init(allocator);
    defer conn.deinit();

    const db_host = get_db_host_env();
    const connection_string = std.fmt.allocPrint(allocator, "postgresql://postgres:postgres@{s}:5432", .{db_host}) catch "postgresql://postgres:postgres@localhost:5432";
    defer allocator.free(connection_string);

    try conn.connect(connection_string);

    var runner = MigrationRunner.init(&conn, allocator);

    // Ensure migration table exists
    try runner.ensureMigrationTable();

    // Create test migration
    const migration = Migration{
        .version = 1001,
        .name = "test_migration",
        .up_sql = "CREATE TABLE migration_test (id SERIAL PRIMARY KEY, data TEXT)",
        .down_sql = "DROP TABLE migration_test",
    };

    // Apply migration
    try runner.applyMigration(migration);

    // Verify table was created
    var result = try conn.execSafe("SELECT COUNT(*) as count FROM information_schema.tables WHERE table_name = 'migration_test'");
    if (result.next()) |row| {
        const count = try row.get("count", i64);
        try std.testing.expectEqual(@as(i64, 1), count);
    }

    // Verify migration was recorded
    result = try conn.execSafe("SELECT COUNT(*) as count FROM schema_migrations WHERE version = 1001");
    if (result.next()) |row| {
        const count = try row.get("count", i64);
        try std.testing.expectEqual(@as(i64, 1), count);
    }

    // Test applying same migration again (should be skipped)
    try runner.applyMigration(migration);

    // Rollback migration
    try runner.rollbackMigration(migration);

    // Verify table was dropped
    result = try conn.execSafe("SELECT COUNT(*) as count FROM information_schema.tables WHERE table_name = 'migration_test'");
    if (result.next()) |row| {
        const count = try row.get("count", i64);
        try std.testing.expectEqual(@as(i64, 0), count);
    }

    // Verify migration record was removed
    result = try conn.execSafe("SELECT COUNT(*) as count FROM schema_migrations WHERE version = 1001");
    if (result.next()) |row| {
        const count = try row.get("count", i64);
        try std.testing.expectEqual(@as(i64, 0), count);
    }
}

test "error handling integration" {
    if (try std.process.hasEnvVar(std.testing.allocator, "SKIP_INTEGRATION_TESTS")) {
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var conn = Connection.init(allocator);
    defer conn.deinit();

    const db_host = get_db_host_env();
    const connection_string = std.fmt.allocPrint(allocator, "postgresql://postgres:postgres@{s}:5432", .{db_host}) catch "postgresql://postgres:postgres@localhost:5432";
    defer allocator.free(connection_string);

    try conn.connect(connection_string);

    // Test query error
    const result = conn.execSafe("SELECT * FROM nonexistent_table");
    try std.testing.expectError(PostgresError.QueryFailed, result);

    // Test detailed error info
    const error_info = conn.getDetailedError();
    try std.testing.expect(error_info.message.len > 0);
    try std.testing.expect(error_info.sqlstate.len > 0);
}

test "null value handling integration" {
    if (try std.process.hasEnvVar(std.testing.allocator, "SKIP_INTEGRATION_TESTS")) {
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var conn = Connection.init(allocator);
    defer conn.deinit();

    const db_host = get_db_host_env();
    const connection_string = std.fmt.allocPrint(allocator, "postgresql://postgres:postgres@{s}:5432", .{db_host}) catch "postgresql://postgres:postgres@localhost:5432";
    defer allocator.free(connection_string);

    try conn.connect(connection_string);

    // Setup test table with nullable columns
    try conn.exec("DROP TABLE IF EXISTS test_nulls", .{});
    try conn.exec("CREATE TABLE test_nulls (id SERIAL PRIMARY KEY, name TEXT, age INTEGER)", .{});
    try conn.exec("INSERT INTO test_nulls (name, age) VALUES ('Alice', 25)", .{});
    try conn.exec("INSERT INTO test_nulls (name, age) VALUES (NULL, NULL)", .{});

    var result = try conn.execSafe("SELECT id, name, age FROM test_nulls ORDER BY id");

    // First row - non-null values
    if (result.next()) |row| {
        const name = try row.get("name", []const u8);
        const age = try row.get("age", i32);
        try std.testing.expectEqualStrings("Alice", name);
        try std.testing.expectEqual(@as(i32, 25), age);

        // Test optional access
        const opt_name = try row.getOpt("name", []const u8);
        const opt_age = try row.getOpt("age", i32);
        try std.testing.expect(opt_name != null);
        try std.testing.expect(opt_age != null);
        try std.testing.expectEqualStrings("Alice", opt_name.?);
        try std.testing.expectEqual(@as(i32, 25), opt_age.?);
    }

    // Second row - null values
    if (result.next()) |row| {
        // Test that accessing null values returns error
        try std.testing.expectError(PostgresError.NullValue, row.get("name", []const u8));
        try std.testing.expectError(PostgresError.NullValue, row.get("age", i32));

        // Test optional access returns null
        const opt_name = try row.getOpt("name", []const u8);
        const opt_age = try row.getOpt("age", i32);
        try std.testing.expect(opt_name == null);
        try std.testing.expect(opt_age == null);
    }

    // Clean up
    try conn.exec("DROP TABLE test_nulls", .{});
}
