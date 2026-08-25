# questdb.luajit

面向 LuaJIT 的 QuestDB FFI 封装。底层调用
[c-questdb-client](https://github.com/questdb/c-questdb-client) 的 C ABI，当前实现聚焦于易用的行式写入 API 和无精度损失的时间戳值对象。

当前版本是第一阶段 MVP：

- 支持 `line_sender` 行式写入；
- 支持 `DATE`、`TIMESTAMP`、`TIMESTAMP_NANOS` 字段和指定时间戳；
- 支持 HTTP、TCP、UDP 等由上游连接字符串选择的传输；
- 支持结构化错误、显式 close 和 `ffi.gc` 兜底；
- 暂未实现 QWP 列式 chunk、SQL reader、Arrow 和连接池高级封装。

这是一个源码方式使用的 Lua 模块，不需要再编译 Lua C 扩展。只要 LuaJIT
能找到 `libquestdb_client`，就可以直接加载 `lua/questdb` 下的文件。

> 兼容性提示：`TIMESTAMP_NANOS` 需要服务端支持该列类型。QuestDB 8.0.1
> 会拒绝 `CREATE TABLE ... TIMESTAMP_NANOS`，只能使用普通
> `TIMESTAMP`（微秒）。如果把纳秒值发送到普通 `TIMESTAMP`，服务端会按
> 列精度降为微秒；Lua 层不会在调用 C API 前主动丢掉纳秒，但也无法提升
> 服务端 schema 的精度。

## 依赖

运行时需要：

- LuaJIT 2.1（提供 `ffi`）；
- 已编译的 `libquestdb_client.so`、`.dylib` 或 Windows `.dll`；
- 与共享库版本匹配的 c-questdb-client C 头文件仅在开发/核对 ABI 时需要。

本机安装方式是：

```text
/usr/local/include/questdb/*.h
/usr/local/lib/libquestdb_client.so
```

`native.lua` 会按以下顺序寻找库：

1. `sender { lib = "/path/to/libquestdb_client.so" }`；
2. `QUESTDB_CLIENT_LIB` 或 `QUESTDB_CLIENT_LIBRARY` 环境变量；
3. 系统动态链接器中的 `questdb_client`；
4. `libquestdb_client.so` 和 `/usr/local/lib/libquestdb_client.so`。

如果需要从上游源码重新构建，要求 Rust、C11/C++17 和 CMake。上游库建议用 `-DBUILD_SHARED_LIBS=ON` 构建；LuaJIT 不能直接加载 `.a` 静态库。

## 安装与加载

仓库目前没有单独的包管理器安装步骤。把仓库中的 `lua` 目录加入
`LUA_PATH` 即可：

```bash
export LUA_PATH='/path/to/questdb.luajit/lua/?.lua;/path/to/questdb.luajit/lua/?/init.lua;;'
luajit your-program.lua
```

也可以在命令前临时设置：

```bash
LUA_PATH='./lua/?.lua;./lua/?/init.lua;;' luajit examples/insert.lua
```

动态库通常放在系统链接器路径（例如 `/usr/local/lib`）。如果不在这些路径，
用 `QUESTDB_CLIENT_LIB` 指定绝对路径，或在 `qdb.sender` 选项中传入 `lib`。

## 快速开始

先在 QuestDB 中创建表。为了兼容 QuestDB 8.0.x，下面先使用普通
`TIMESTAMP`（微秒）列：

```sql
CREATE TABLE trades (
  sym SYMBOL,
  price DOUBLE,
  qty LONG,
  ts TIMESTAMP
) TIMESTAMP(ts) PARTITION BY DAY;
```

如果服务端版本明确支持 `TIMESTAMP_NANOS`，可以把列改成纳秒类型，并在
Lua 中使用 `qdb.time.ns(...)`：

```sql
CREATE TABLE trades (
  sym SYMBOL,
  price DOUBLE,
  qty LONG,
  ts TIMESTAMP_NANOS
) TIMESTAMP(ts) PARTITION BY DAY;
```

保存下面的 Lua 代码为 `examples/insert.lua`，或直接运行仓库内的示例：

```lua
local qdb = require "questdb"

local sender, err = qdb.sender {
  conf = "http::addr=localhost:9000;",
}
assert(sender, tostring(err))

local row
row, err = sender:row("trades")
assert(row, tostring(err))
assert(row:symbol("sym", "BTC-USD"))
assert(row:double("price", 42000.25))
assert(row:int64("qty", 2))
assert(row:at(qdb.time.us("1700000000123456")))
assert(row:send())

sender:close()
```

使用仓库内的 Lua 模块运行：

```bash
LUA_PATH='./lua/?.lua;./lua/?/init.lua;;' luajit examples/insert.lua
```

也可以显式指定动态库：

```lua
local sender, err = qdb.sender {
  lib = "/opt/questdb/lib/libquestdb_client.so",
  conf = "http::addr=localhost:9000;",
}
```

## API

### Sender

```lua
local sender, err = qdb.sender {
  conf = "http::addr=localhost:9000;",
  reserve = 64 * 1024, -- 可选，预留 buffer 容量
}

local row, err = sender:row("table_name")
row:symbol("symbol_col", "value")
row:string("text_col", "hello")
row:bool("active", true)
row:int64("count", 42)
row:double("price", 12.5)
row:at(qdb.time.us(1700000000123456))
local ok, send_err = row:send()
```

`row:send()` 会立即 flush 当前 buffer，适合低延迟的逐行写入。需要批量写入时，
保留 `buffer`，每次用 `row:at()` 或 `row:at_now()` 结束当前行，最后显式
`buffer:flush()`：

```lua
local buffer = sender:buffer()
for i = 1, 1000 do
  local row = assert(buffer:row("trades"))
  assert(row:symbol("sym", "BTC-USD"))
  assert(row:int64("qty", i))
  assert(row:at_now())
  -- at_now() 结束当前行，但不会 flush；下一次 buffer:row() 开始下一行
end
assert(buffer:flush())
```

`buffer:row()` 调用上游的 `line_sender_buffer_table()` 开始下一行，因此循环中
不需要额外的 `finish_row()` 方法。一个 buffer 可以在 flush 后继续复用。

### 时间戳

时间戳是带单位的不可变值对象：

```lua
local ms = qdb.time.ms(1700000000123)
local us = qdb.time.us(1700000000123456)
local ns = qdb.time.ns("1700000000123456789")

print(ns:unit())       -- ns
print(ns:raw())        -- int64_t cdata
print(ns:to_string())  -- 2023-11-14T22:13:20.123456789Z
```

QuestDB 的单位对应关系：

| QuestDB 类型 | 单位 | Lua 构造函数 |
| --- | --- | --- |
| `DATE` | epoch 毫秒 | `qdb.time.ms(value)` |
| `TIMESTAMP` | epoch 微秒 | `qdb.time.us(value)` |
| `TIMESTAMP_NANOS` | epoch 纳秒 | `qdb.time.ns(value)` |

LuaJIT 默认 `number` 是 double，只有绝对值不超过 `2^53` 的整数可以保证精确。当前 epoch 的纳秒值约为 `1.7e18`，不能写成 Lua 数字：

```lua
-- 错误：数字字面量先经过 double，纳秒末尾可能已经被舍入
qdb.time.ns(1700000000123456789)
```

应该使用十进制字符串、已有的 `int64_t` cdata，或由秒和小数部分构造：

```lua
qdb.time.ns("1700000000123456789")
qdb.time.from_unix(1700000000, 123456789, "ns")
qdb.time.now_ns()
```

降精度默认拒绝隐式损失：

```lua
local ns = qdb.time.ns("1700000000123456789")
local ok, err = pcall(function() return ns:to_us() end)
assert(not ok) -- 789 纳秒不能精确转换为微秒

local us = ns:to_us { mode = "truncate" }
local rounded = ns:to_us { mode = "round" }
```

RFC3339 只用于 Lua 输入输出，C ABI 传输的仍然是有符号 `int64_t` epoch 整数：

```lua
local t = qdb.time.parse_rfc3339("2024-02-29T12:34:56.123456789+08:00")
assert(t:to_string() == "2024-02-29T04:34:56.123456789Z")

local us = qdb.time.parse_rfc3339(
  "2024-02-29T12:34:56.123456Z",
  { unit = "us" }
)
```

`parse_rfc3339` 默认返回纳秒对象。指定更低精度时，如果存在不可表示的小数，必须显式传入 `precision = "truncate"` 或 `"round"`。

### 字段时间戳

除指定时间戳外，也可以写入普通时间列：

```lua
row:date("created_at", qdb.time.ms(1700000000123))
row:timestamp("event_time", qdb.time.us(1700000000123456))
row:timestamp_ns("high_precision_time", qdb.time.ns("1700000000123456789"))
```

`row:timestamp()` 根据值对象单位选择微秒或纳秒；目标 QuestDB 列的类型应与单位匹配，不依赖服务端隐式转换。当前服务端不支持 `TIMESTAMP_NANOS` 时，应使用 `qdb.time.us(...)` 和普通 `TIMESTAMP`。

服务端不会因为客户端传入了 9 位小数就自动获得纳秒列。比如 QuestDB 8.0.1
不接受 `TIMESTAMP_NANOS` schema；把 `1700000000123456789` ns 写进普通
`TIMESTAMP` 后，服务端会按微秒保存并读回 `...123456Z`。因此应先确认
schema 的列类型，再选择 `time.us` 或 `time.ns`。可以在控制台执行
`select build()` 查看服务端版本。

### 错误处理和资源

写入和资源操作采用 `true` 或 `nil, error` 返回约定；查询类方法如
`buffer:size()`、`buffer:row_count()` 会返回数值，`sender:must_close()`
会返回布尔值：

```lua
local ok, err = row:send()
if not ok then
  print(err.code, err.native_code, err.message, err.in_doubt)
end
```

原生错误会在读取 `code`、`message` 和 `in_doubt` 后立即释放。`sender:close()` 和 `buffer:close()` 对调用方幂等，但不要依赖 GC 完成 flush；需要发送的数据必须显式 `send()` 或 `flush()`。

sender、buffer 和 row 不应跨 LuaJIT state 或并发线程共享。一个 sender 的 buffer 只属于该 sender。

## 测试

纯 Lua 时间测试和共享库 FFI smoke test 不需要 QuestDB 服务端：

```bash
make test
```

测试会验证：

- `2^53` 安全边界；
- 纳秒字符串和 int64 cdata；
- RFC3339、时区偏移和负 epoch；
- 精确/截断/舍入转换；
- `int64_t` 上下界和溢出；
- `/usr/local/lib/libquestdb_client.so` 的动态加载和当前时间函数。

真实写入测试需要本地 QuestDB，例如 HTTP 端口 `9000`。当前仓库没有自动启动或下载 QuestDB 服务端。若服务端不支持 `TIMESTAMP_NANOS`，请先查询 `select build()` 并按服务端版本选择 `TIMESTAMP`/微秒路径。

当前验证过的环境包括 LuaJIT 2.1、本机 `/usr/local/lib/libquestdb_client.so`
以及 QuestDB 8.0.1 的 HTTP 写入路径；远端测试只追加测试行，不会由测试脚本
删除或修改已有数据。

## 开发约定

- `lua/questdb/native.lua` 是唯一的 FFI ABI 声明入口。
- 当前公开入口是 `qdb.sender`、`qdb.time`；QWP、SQL reader、Arrow 和连接池仍属于后续工作。
- `time.lua` 内部禁止使用 `tonumber` 作为纳秒值的中间表示；只有明确要求安全范围内 Lua 数字时才转换。
- 新增 C API 前先核对 `/usr/local/include/questdb` 与共享库版本，然后补充 FFI smoke test。
- 对可能产生精度损失、资源泄漏或 borrowed memory 生命周期变化的改动，必须补测试和 README 说明。
