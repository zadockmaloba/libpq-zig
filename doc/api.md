# API Reference

## Core Types

### Connection

The main database connection type.

```zig
const Connection = struct {
    pq: ?*libpq.PGconn,
    last_result: ?*libpq.PGresult,
    is_reading: bool,
    is_reffed: bool,
    result_buffer: std.StringArrayHashMap(PgType),
    allocator: std.mem.Allocator,
    format_buffer: [16 * 1024]u8,
    prepared_statements: std.StringHashMap(void),
};
```

#### Methods

##### `init(allocator: std.mem.Allocator) Connection`

Creates a new connection instance.

**Parameters:**
- `allocator`: Memory allocator for the connection

**Returns:** A new `Connection` instance

##### `deinit(self: *@This()) void`

Cleans up connection resources.

##### `connect(self: *@This(), connString: []const u8) !void`

Establishes a connection to PostgreSQL.

**Parameters:**
- `connString`: PostgreSQL connection string (e.g., "postgresql://user:pass@host:port/db")

**Errors:**
- `PostgresError.ConnectionFailed`: Failed to establish connection

##### `connectWithSSL(self: *@This(), connString: []const u8, ssl_config: SSLConfig) !void`

Establishes a connection with SSL configuration.

**Parameters:**
- `connString`: Base connection string
- `ssl_config`: SSL configuration options

##### `exec(self: *@This(), comptime query: []const u8, argv: anytype) !void`

Executes a formatted query (unsafe - use for trusted input only).

**Parameters:**
- `query`: SQL query with format specifiers
- `argv`: Arguments for format specifiers

**Errors:**
- `PostgresError.QueryFailed`: Query execution failed

##### `execSafe(self: *@This(), query: []const u8) !ResultSet`

Executes a query safely without format strings.

**Parameters:**
- `query`: SQL query string

**Returns:** `ResultSet` containing query results

**Errors:**
- `PostgresError.QueryFailed`: Query execution failed

##### `prepare(self: *@This(), name: []const u8, query: []const u8, param_types: []const u32) !void`

Prepares a statement for later execution.

**Parameters:**
- `name`: Unique name for the prepared statement
- `query`: SQL query with parameter placeholders ($1, $2, etc.)
- `param_types`: PostgreSQL OIDs for parameter types

**Errors:**
- `PostgresError.PreparedStatementFailed`: Statement preparation failed

##### `execPrepared(self: *@This(), stmt_name: []const u8, params: []const ?[]const u8) !ResultSet`

Executes a prepared statement.

**Parameters:**
- `stmt_name`: Name of the prepared statement
- `params`: Parameter values (null for NULL values)

**Returns:** `ResultSet` containing query results

##### `beginTransaction(self: *@This()) !void`

Begins a database transaction.

**Errors:**
- `PostgresError.TransactionBeginFailed`: Failed to begin transaction

##### `commit(self: *@This()) !void`

Commits the current transaction.

**Errors:**
- `PostgresError.TransactionCommitFailed`: Failed to commit transaction

##### `rollback(self: *@This()) !void`

Rolls back the current transaction.

**Errors:**
- `PostgresError.TransactionRollbackFailed`: Failed to rollback transaction

##### `savepoint(self: *@This(), name: []const u8) !void`

Creates a savepoint within a transaction.

**Parameters:**
- `name`: Name of the savepoint

##### `rollbackToSavepoint(self: *@This(), name: []const u8) !void`

Rolls back to a specific savepoint.

**Parameters:**
- `name`: Name of the savepoint

### ResultSet

Container for query results with iteration support.

```zig
const ResultSet = struct {
    result: *libpq.PGresult,
    current_row: i32,
    total_rows: i32,
    allocator: std.mem.Allocator,
};
```

#### Methods

##### `init(result: *libpq.PGresult, allocator: std.mem.Allocator) ResultSet`

Creates a new ResultSet from a libpq result.

##### `next(self: *@This()) ?Row`

Returns the next row or null if no more rows.

**Returns:** Optional `Row` instance

##### `rowCount(self: *@This()) i32`

Returns the total number of rows.

##### `columnCount(self: *@This()) i32`

Returns the number of columns.

### Row

Represents a single row in a result set.

```zig
const Row = struct {
    result: *libpq.PGresult,
    row_index: i32,
    allocator: std.mem.Allocator,
};
```

#### Methods

##### `get(self: *@This(), column: []const u8, comptime T: type) !T`

Gets a column value with type conversion.

**Parameters:**
- `column`: Column name
- `T`: Target type

**Returns:** Value of type `T`

**Errors:**
- `PostgresError.NoSuchColumn`: Column doesn't exist
- `PostgresError.NullValue`: Column value is NULL
- `PostgresError.TypeMismatch`: Type conversion failed

##### `getOpt(self: *@This(), column: []const u8, comptime T: type) !?T`

Gets an optional column value.

**Parameters:**
- `column`: Column name
- `T`: Target type

**Returns:** Optional value of type `T`

### ConnectionPool

Thread-safe connection pool for high-performance applications.

```zig
const ConnectionPool = struct {
    connections: std.ArrayList(*Connection),
    available: std.ArrayList(*Connection),
    mutex: std.Thread.Mutex,
    max_connections: u32,
    min_connections: u32,
    allocator: std.mem.Allocator,
    connection_string: []const u8,
};
```

#### Methods

##### `init(allocator: std.mem.Allocator, connection_string: []const u8, min_connections: u32, max_connections: u32) !ConnectionPool`

Creates a new connection pool.

**Parameters:**
- `allocator`: Memory allocator
- `connection_string`: PostgreSQL connection string
- `min_connections`: Minimum number of connections to maintain
- `max_connections`: Maximum number of connections

##### `acquire(self: *@This()) !*Connection`

Acquires a connection from the pool.

**Returns:** Available `Connection` instance

**Errors:**
- `PostgresError.PoolExhausted`: No connections available

##### `release(self: *@This(), conn: *Connection) void`

Returns a connection to the pool.

**Parameters:**
- `conn`: Connection to return

### QueryBuilder

Fluent API for building parameterized queries.

```zig
const QueryBuilder = struct {
    query: std.ArrayList(u8),
    params: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
};
```

#### Methods

##### `init(allocator: std.mem.Allocator) QueryBuilder`

Creates a new query builder.

##### `sql(self: *@This(), text: []const u8) !*@This()`

Appends SQL text to the query.

**Parameters:**
- `text`: SQL text to append

**Returns:** Self for method chaining

##### `bind(self: *@This(), value: anytype) !*@This()`

Binds a parameter value.

**Parameters:**
- `value`: Value to bind

**Returns:** Self for method chaining

##### `build(self: *@This()) []const u8`

Returns the built query string.

## Enums and Types

### PgType

Union type representing PostgreSQL data types.

```zig
const PgType = union(enum) {
    // Numeric types
    smallint: i16,
    integer: i32,
    bigint: i64,
    real: f32,
    double: f64,
    numeric: []const u8,

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
```

### PostgresError

Error types that can be returned by libpq-zig operations.

```zig
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
```

### SSLConfig

Configuration for SSL connections.

```zig
const SSLConfig = struct {
    mode: enum { disable, allow, prefer, require, verify_ca, verify_full },
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    ca_file: ?[]const u8 = null,
};
```

## Utility Functions

### `createConnectionString(allocator: std.mem.Allocator, host: []const u8, port: u16, database: []const u8, username: []const u8, password: []const u8) ![]u8`

Creates a PostgreSQL connection string from components.

### `parseUUID(uuid_str: []const u8) ![16]u8`

Parses a UUID string into a byte array.

### `formatUUID(uuid_bytes: [16]u8, allocator: std.mem.Allocator) ![]u8`

Formats a UUID byte array into a string.

## Migration System

### Migration

Represents a database migration.

```zig
const Migration = struct {
    version: u32,
    name: []const u8,
    up_sql: []const u8,
    down_sql: []const u8,
};
```

### MigrationRunner

Manages database migrations.

```zig
const MigrationRunner = struct {
    connection: *Connection,
    allocator: std.mem.Allocator,
};
```

#### Methods

##### `init(connection: *Connection, allocator: std.mem.Allocator) MigrationRunner`

Creates a new migration runner.

##### `ensureMigrationTable(self: *@This()) !void`

Creates the schema_migrations table if it doesn't exist.

##### `applyMigration(self: *@This(), migration: Migration) !void`

Applies a migration to the database.

##### `rollbackMigration(self: *@This(), migration: Migration) !void`

Rolls back a migration from the database.

## Connection Monitoring

### ConnectionMetrics

Tracks connection performance metrics.

```zig
const ConnectionMetrics = struct {
    total_queries: u64,
    successful_queries: u64,
    failed_queries: u64,
    total_connection_time: u64,
    last_activity: i64,
};
```

#### Methods

##### `recordQuery(self: *@This(), success: bool, duration_ms: u64) void`

Records query execution metrics.

##### `getSuccessRate(self: *@This()) f64`

Returns the query success rate (0.0 to 1.0).

##### `getAverageQueryTime(self: *@This()) f64`

Returns the average query execution time in milliseconds.