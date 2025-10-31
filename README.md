# libpq-zig

A comprehensive Zig wrapper around the PostgreSQL libpq library, providing a type-safe, idiomatic interface for PostgreSQL database operations in Zig.

## Features

- ✅ **Type-safe PostgreSQL types** - Comprehensive PgType enum supporting all major PostgreSQL data types
- ✅ **Connection management** - Simple connection handling with SSL support
- ✅ **Connection pooling** - Built-in connection pool for high-performance applications
- ✅ **Prepared statements** - Safe parameterized queries with type checking
- ✅ **Transaction support** - Full transaction management including savepoints
- ✅ **Async operations** - Non-blocking query execution
- ✅ **Migration system** - Database schema migration utilities
- ✅ **Bulk operations** - Efficient COPY operations for large data transfers
- ✅ **Query builder** - Fluent query building API
- ✅ **Error handling** - Detailed PostgreSQL error information
- ✅ **Connection monitoring** - Built-in metrics and health checking

## Requirements

- Zig 0.15.2 or later
- PostgreSQL development libraries (libpq)

## Installation

Add libpq-zig to your `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .libpq_zig = .{
            .url = "https://github.com/your-username/libpq-zig/archive/main.tar.gz",
            .hash = "1234...", // Use `zig fetch` to get the correct hash
        },
    },
}
```

Then in your `build.zig`:

```zig
const libpq_zig = b.dependency("libpq_zig", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("libpq_zig", libpq_zig.module("libpq_zig"));
```

## Quick Start

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

    // Connect to database
    const conn_string = "postgresql://user:password@localhost:5432/mydb";
    try conn.connect(conn_string);

    // Execute a simple query
    var result = try conn.execSafe("SELECT name, age FROM users WHERE active = true");
    
    // Iterate through results
    while (result.next()) |row| {
        const name = try row.get("name", []const u8);
        const age = try row.get("age", i32);
        std.debug.print("User: {s}, Age: {d}\n", .{ name, age });
    }
}
```

## Documentation

- [API Reference](doc/api.md) - Complete API documentation
- [Connection Management](doc/connections.md) - Connection setup and configuration
- [Query Operations](doc/queries.md) - Executing queries and handling results
- [Type System](doc/types.md) - PostgreSQL type mapping
- [Transactions](doc/transactions.md) - Transaction management
- [Connection Pooling](doc/connection-pooling.md) - Using connection pools
- [Migrations](doc/migrations.md) - Database schema migrations
- [Error Handling](doc/error-handling.md) - Error handling strategies
- [Examples](doc/examples/) - Code examples and tutorials

## Basic Usage

### Simple Query Execution

```zig
// Execute a query without parameters
var result = try conn.execSafe("SELECT * FROM users");

// Execute with format parameters (unsafe - use for trusted input only)
try conn.exec("INSERT INTO logs (message) VALUES ('{s}')", .{"User logged in"});
```

### Prepared Statements

```zig
// Prepare a statement
try conn.prepare("get_user", "SELECT * FROM users WHERE id = $1", &[_]u32{23}); // int4

// Execute prepared statement
const user_id = "123";
var result = try conn.execPrepared("get_user", &[_]?[]const u8{user_id});
```

### Query Builder

```zig
var builder = libpq.QueryBuilder.init(allocator);
defer builder.deinit();

_ = try builder.sql("SELECT name, email FROM users WHERE age > ");
_ = try builder.bind(@as(i32, 18));
_ = try builder.sql(" AND active = ");
_ = try builder.bind(true);

const query = builder.build();
var result = try conn.execSafe(query);
```

### Transactions

```zig
try conn.beginTransaction();
defer conn.rollback() catch {}; // Rollback on error

try conn.exec("INSERT INTO users (name) VALUES ('Alice')", .{});
try conn.exec("UPDATE counters SET value = value + 1", .{});

try conn.commit(); // Only commits if we reach this point
```

### Connection Pooling

```zig
var pool = try libpq.ConnectionPool.init(
    allocator,
    "postgresql://user:pass@localhost/db",
    5,  // min connections
    20  // max connections
);
defer pool.deinit();

// Acquire connection from pool
const conn = try pool.acquire();
defer pool.release(conn);

// Use connection normally
var result = try conn.execSafe("SELECT * FROM products");
```

## Type Mapping

| PostgreSQL Type | Zig Type | PgType Variant |
|----------------|----------|----------------|
| `BOOLEAN` | `bool` | `.boolean` |
| `SMALLINT` | `i16` | `.smallint` |
| `INTEGER` | `i32` | `.integer` |
| `BIGINT` | `i64` | `.bigint` |
| `REAL` | `f32` | `.real` |
| `DOUBLE PRECISION` | `f64` | `.double` |
| `VARCHAR`, `TEXT` | `[]const u8` | `.varchar`, `.text` |
| `DATE` | `Date` | `.date` |
| `TIMESTAMP` | `DateTime` | `.timestamp` |
| `TIMESTAMPTZ` | `DateTimeTz` | `.timestamptz` |
| `JSON`, `JSONB` | `[]const u8` | `.json`, `.jsonb` |
| `UUID` | `[16]u8` | `.uuid` |
| `BYTEA` | `[]const u8` | `.bytea` |

## Error Handling

libpq-zig provides comprehensive error handling:

```zig
const result = conn.execSafe("SELECT * FROM nonexistent_table");
if (result) |res| {
    // Handle successful result
} else |err| switch (err) {
    libpq.PostgresError.NoSuchTable => {
        std.debug.print("Table does not exist\n", .{});
    },
    libpq.PostgresError.ConnectionFailed => {
        std.debug.print("Database connection failed\n", .{});
    },
    else => {
        // Get detailed error information
        const error_info = conn.getDetailedError();
        std.debug.print("Error: {s}\nSQLSTATE: {s}\n", .{ error_info.message, error_info.sqlstate });
    },
}
```

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Development Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/libpq-zig.git
   cd libpq-zig
   ```

2. Install PostgreSQL development libraries:
   ```bash
   # Ubuntu/Debian
   sudo apt-get install libpq-dev
   
   # macOS
   brew install postgresql
   
   # Arch Linux
   sudo pacman -S postgresql-libs
   ```

3. Run tests:
   ```bash
   zig build test
   ```

## Testing

The library includes comprehensive tests. To run them, you'll need a PostgreSQL instance running:

```bash
# Start PostgreSQL (using Docker)
docker run --name postgres-test -e POSTGRES_PASSWORD=postgres -p 5432:5432 -d postgres

# Run tests
zig build test

# Clean up
docker stop postgres-test
docker rm postgres-test
```

Set the `DB_HOST` environment variable to specify a different host:

```bash
DB_HOST=localhost zig build test
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built on top of the excellent [libpq](https://www.postgresql.org/docs/current/libpq.html) PostgreSQL client library
- Inspired by database libraries in other languages like [sqlx](https://github.com/launchbadge/sqlx) for Rust

## Roadmap

- [ ] Streaming result sets for large queries
- [ ] Connection load balancing
- [ ] Advanced prepared statement caching
- [ ] PostgreSQL LISTEN/NOTIFY support
- [ ] Connection retry strategies
- [ ] Performance benchmarks and optimizations
- [ ] Full PostgreSQL type coverage (arrays, custom types, etc.)
- [ ] Connection string parsing utilities
- [ ] SSL certificate validation helpers