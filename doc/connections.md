# Connection Management

This guide covers establishing and managing database connections with libpq-zig.

## Basic Connection Setup

### Simple Connection

```zig
const std = @import("std");
const libpq = @import("libpq_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create connection
    var conn = libpq.Connection.init(allocator);
    defer conn.deinit();

    // Connect using connection string
    try conn.connect("postgresql://username:password@localhost:5432/database_name");

    // Verify connection
    if (conn.ping()) {
        std.debug.print("Successfully connected to PostgreSQL\n", .{});
    }
}
```

### Connection String Formats

libpq-zig supports standard PostgreSQL connection strings:

#### URL Format
```
postgresql://[user[:password]@][host][:port][/database][?param1=value1&...]
```

#### Key-Value Format
```
host=localhost port=5432 dbname=mydb user=myuser password=mypass
```

### Connection String Builder

For programmatic connection string construction:

```zig
const conn_string = try libpq.createConnectionString(
    allocator,
    "localhost",    // host
    5432,          // port
    "mydb",        // database
    "myuser",      // username
    "mypass"       // password
);
defer allocator.free(conn_string);

try conn.connect(conn_string);
```

## SSL/TLS Configuration

### SSL Modes

```zig
const ssl_config = libpq.SSLConfig{
    .mode = .require,  // Options: disable, allow, prefer, require, verify_ca, verify_full
    .cert_file = "client-cert.pem",
    .key_file = "client-key.pem",
    .ca_file = "ca-cert.pem",
};

try conn.connectWithSSL("postgresql://user:pass@host/db", ssl_config);
```

### SSL Mode Descriptions

- **disable**: No SSL connection attempted
- **allow**: Try non-SSL first, then SSL if that fails
- **prefer**: Try SSL first, then non-SSL if that fails (default)
- **require**: Only SSL connections, but don't verify certificates
- **verify-ca**: SSL connection with certificate verification
- **verify-full**: SSL connection with full certificate verification

## Environment Variables

libpq-zig respects standard PostgreSQL environment variables:

```bash
export PGHOST=localhost
export PGPORT=5432
export PGDATABASE=mydb
export PGUSER=myuser
export PGPASSWORD=mypass
export PGSSLMODE=require
```

Then connect without parameters:
```zig
try conn.connect("");  // Uses environment variables
```

## Connection Options

### Timeouts

```zig
// Connection string with timeout parameters
const conn_string = "postgresql://user:pass@host/db" ++
    "?connect_timeout=10" ++         // 10 second connection timeout
    "&command_timeout=30" ++         // 30 second command timeout
    "&keepalives_idle=600" ++        // TCP keepalive settings
    "&keepalives_interval=30" ++
    "&keepalives_count=3";

try conn.connect(conn_string);
```

### Application Name

Set an application name for connection tracking:

```zig
const conn_string = "postgresql://user:pass@host/db?application_name=MyApp";
try conn.connect(conn_string);
```

## Connection Health and Monitoring

### Health Checks

```zig
// Check if connection is alive
if (!conn.ping()) {
    std.debug.print("Connection lost, attempting reconnect...\n", .{});
    try conn.reconnect();
}
```

### Server Information

```zig
// Get server version
const server_version = conn.serverVersion();
std.debug.print("PostgreSQL server version: {d}\n", .{server_version});

// Get client library version
const client_version = conn.clientVersion();
std.debug.print("libpq client version: {d}\n", .{client_version});
```

### Error Information

```zig
// Get last error message
if (conn.getLastErrorMessage()) |error_msg| {
    std.debug.print("Connection error: {s}\n", .{error_msg});
}

// Get detailed error information (after a failed query)
const error_info = conn.getDetailedError();
std.debug.print("Error: {s}\n", .{error_info.message});
std.debug.print("SQLSTATE: {s}\n", .{error_info.sqlstate});
std.debug.print("Severity: {s}\n", .{error_info.severity});
if (error_info.detail.len > 0) {
    std.debug.print("Detail: {s}\n", .{error_info.detail});
}
if (error_info.hint.len > 0) {
    std.debug.print("Hint: {s}\n", .{error_info.hint});
}
```

## Asynchronous Connections

### Non-blocking Mode

```zig
// Enable non-blocking mode
try conn.setNonBlocking(true);

// Check if connection is in non-blocking mode
if (conn.isNonBlocking()) {
    std.debug.print("Connection is in non-blocking mode\n", .{});
}

// Execute async query
try conn.execAsync("SELECT * FROM large_table");

// Poll for results
while (true) {
    if (try conn.getResult()) |result| {
        // Process result
        break;
    }
    // Do other work while query executes
    std.time.sleep(std.time.ns_per_ms * 10); // Sleep 10ms
}
```

## Connection Lifecycle

### Proper Cleanup

Always ensure proper cleanup of connections:

```zig
var conn = libpq.Connection.init(allocator);
defer conn.deinit(); // This will close the connection and free resources

// Or explicitly close if needed
if (some_condition) {
    conn.deinit();
    return;
}
```

### Connection Reuse

Connections can be reused for multiple operations:

```zig
var conn = libpq.Connection.init(allocator);
defer conn.deinit();

try conn.connect(conn_string);

// Perform multiple operations
try conn.exec("CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, name TEXT)", .{});
try conn.exec("INSERT INTO users (name) VALUES ('Alice')", .{});
var result = try conn.execSafe("SELECT * FROM users");
```

## Best Practices

### 1. Connection String Security

Never hardcode credentials in source code:

```zig
// Bad - credentials in source
try conn.connect("postgresql://user:password123@host/db");

// Good - use environment variables
const conn_string = std.process.getEnvVarOwned(allocator, "DATABASE_URL") catch {
    std.debug.print("DATABASE_URL environment variable not set\n", .{});
    return;
};
defer allocator.free(conn_string);
try conn.connect(conn_string);
```

### 2. Error Handling

Always handle connection errors appropriately:

```zig
conn.connect(conn_string) catch |err| switch (err) {
    libpq.PostgresError.ConnectionFailed => {
        std.debug.print("Failed to connect to database\n", .{});
        return;
    },
    libpq.PostgresError.AuthenticationFailed => {
        std.debug.print("Invalid credentials\n", .{});
        return;
    },
    else => return err,
};
```

### 3. Resource Management

Use defer for automatic cleanup:

```zig
pub fn performDatabaseOperation(allocator: std.mem.Allocator) !void {
    var conn = libpq.Connection.init(allocator);
    defer conn.deinit(); // Guaranteed cleanup

    try conn.connect(conn_string);
    // ... perform operations
} // Connection automatically closed here
```

### 4. Connection Validation

Validate connections before use:

```zig
fn ensureConnection(conn: *libpq.Connection) !void {
    if (!conn.ping()) {
        try conn.reconnect();
        if (!conn.ping()) {
            return libpq.PostgresError.ConnectionFailed;
        }
    }
}
```