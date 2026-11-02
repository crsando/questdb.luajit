# questdb.luajit

面向 LuaJIT 的 QuestDB FFI 封装。底层调用
[c-questdb-client](https://github.com/questdb/c-questdb-client) 的 C ABI，当前实现聚焦于易用的行式写入 API 和无精度损失的时间戳值对象。

当前版本是第一阶段 MVP：

- 支持 `line_sender` 行式写入；
- 支持 `DATE`、`TIMESTAMP`、`TIMESTAMP_NS` 字段和指定时间戳（`DATE` 的传输限制见“字段时间戳”）；
- 支持 HTTP、TCP、UDP 等由上游连接字符串选择的传输；
- 支持结构化错误、显式 close 和 `ffi.gc` 兜底；
- 暂未实现 QWP 列式 chunk、SQL reader、Arrow 和连接池高级封装。

这是一个源码方式使用的 Lua 模块，不需要再编译 Lua C 扩展。只要 LuaJIT
能找到 `libquestdb_client`，就可以直接加载 `lua/questdb` 下的文件。

> 兼容性提示：纳秒列的 SQL 类型名是 `TIMESTAMP_NS`，需要服务端支持
> （已在 QuestDB 10.1.0 上实测）。如果把纳秒值发送到普通 `TIMESTAMP`，
> 服务端会按列精度降为微秒；Lua 层不会在调用 C API 前主动丢掉纳秒，但也
> 无法提升服务端 schema 的精度。

## 支持平台

| 平台 | 共享库 | 状态 |
| --- | --- | --- |
| macOS / Apple Silicon | `libquestdb_client.dylib` | 已验证：编译、测试、写入 |
| Linux / x86_64 | `libquestdb_client.so` | 已验证：编译、测试、写入 |
| macOS / Intel、Linux / aarch64 | 同上 | 路径规则已实现，未实测 |
| Windows（MSYS2/MinGW） | `questdb_client.dll` | 路径规则已实现，未实测 |

平台差异收敛在 `lua/questdb/platform.lua`（库文件名、系统库目录）和
`lua/questdb/native.lua`（搜索顺序），由 `jit.os` 选择。

## 依赖

运行时需要：

- LuaJIT 2.1（提供 `ffi`）；
- 已编译的 `libquestdb_client.dylib` / `.so` / `questdb_client.dll`。

构建上游共享库需要：

- CMake 3.15+ 与 C11/C++17 编译器（macOS 上是 Xcode CLT，Linux 上是
  gcc/clang）；
- **Rust 1.91.1+**。上游 pin 的 crates 使用 edition 2024，旧工具链会在
  `cargo metadata` 阶段直接失败。`make deps` 会先检查版本并给出提示。

LuaJIT 不能加载 `.a` 静态库，必须构建共享库（`-DBUILD_SHARED_LIBS=ON`）。

### 一条命令构建依赖

```bash
make deps          # clone 上游到 build/c-questdb-client，按 pin 的 commit 构建
make deps-check    # 打印平台、搜索路径和实际加载到的库
```

`make deps` 只在共享库缺失或 pin 变化时才做事：

1. 检查 `cargo` 和 `rustc` 的版本（不在 PATH 时也会用 `~/.cargo/bin`，构建阶段
   用的是同一份工具链）；
2. 克隆 [c-questdb-client](https://github.com/questdb/c-questdb-client) 到
   `build/c-questdb-client`，切到 pin 的 commit `8ef0219`（7.0.0+2）；
3. 用 CMake 编出共享库，复制到 `build/lib/`。

产物被 `.gitignore` 忽略。库已是最新时不需要 Rust，也不需要上游源码。

换上游版本时指定 commit，切换（包括切回旧版本）都会触发重建：

```bash
make deps UPSTREAM_COMMIT=<sha>
make abi-check UPSTREAM_COMMIT=<sha>   # 把 cdef 拿去和该版本的头文件一起编译
```

`make abi-check` 校验的是：函数签名、结构体布局、枚举值，以及 `error.lua` 的错误码表。

### 库的搜索顺序

**指定了库时只用它。** 按 `sender { lib = "..." }`、`QUESTDB_CLIENT_LIB`、
`QUESTDB_CLIENT_LIBRARY` 的优先级取第一个（可以是文件或目录）。加载失败就直接报错，
不会悄悄换成别处的另一个版本。

**没指定时才自动搜索：**

1. 仓库内：`build/lib/`、`build/`、`lib/`、`build/c-questdb-client/build-<platform>/`
   ——所以 `make deps` 之后不需要任何环境变量；
2. 裸库名 `questdb_client`、平台默认文件名，交给系统动态链接器；
3. 平台惯例目录：
   - macOS：`/opt/homebrew/lib`、`/usr/local/lib`、`/opt/local/lib`
   - Linux：`/usr/local/lib`、`/usr/lib`、`/usr/lib64`、`/usr/lib/<triplet>`

加载后会检查 `ffi.cdef` 声明的所有符号都存在，缺符号的库算加载失败。全部失败时，
错误信息会列出每个尝试过的路径和原因。这项检查防的是“拿错库”，不能证明库的版本
与声明完全一致：上游库没有导出版本号，所以从系统目录找到的库由使用者保证版本。

一个 Lua state 里第一个成功加载的库会成为默认库，`qdb.time.now_*` 也用它。
`make deps-check` 会打印实际命中的候选。

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

如果共享库不在上面列出的任何位置，用 `QUESTDB_CLIENT_LIB` 指定绝对路径，
或在 `qdb.sender` 选项中传入 `lib`。搞不清加载的是哪个库时跑
`make deps-check`。

## 快速开始

先在 QuestDB 中创建表。下面使用普通 `TIMESTAMP`（微秒）列：

```sql
CREATE TABLE trades (
  sym SYMBOL,
  price DOUBLE,
  qty LONG,
  ts TIMESTAMP
) TIMESTAMP(ts) PARTITION BY DAY;
```

如果服务端支持 `TIMESTAMP_NS`，可以把列改成纳秒类型，并在 Lua 中使用
`qdb.time.ns(...)`：

```sql
CREATE TABLE trades (
  sym SYMBOL,
  price DOUBLE,
  qty LONG,
  ts TIMESTAMP_NS
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

`row:send()` 只发送这一行，适合低延迟的逐行写入。需要批量写入时，保留 `buffer`，
每次用 `row:at()` 或 `row:at_now()` 结束当前行，最后显式 `buffer:flush()`：

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

Row 对象只代表自己那一行，下面这些调用都返回 `invalid_api_call`，不会写入任何数据：

- `at()` / `at_now()` 结束之后，再写字段或再次结束；
- 下一行开始之后，或 buffer 被 flush、clear 之后，继续使用旧 Row；
- buffer 里还有其他行时调用 `row:send()`（批量请用 `buffer:flush()`）。

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
| `TIMESTAMP_NS` | epoch 纳秒 | `qdb.time.ns(value)` |

LuaJIT 默认 `number` 是 double，只有绝对值小于 `2^53` 的整数可以保证精确，`time.ms/us/ns` 也只接受这个范围内的数字（`2^53 + 1` 会被舍入成 `2^53`，所以 `2^53` 本身同样拒绝）。当前 epoch 的纳秒值约为 `1.7e18`，不能写成 Lua 数字：

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

`parse_rfc3339` 默认返回纳秒对象。指定更低精度时，如果存在不可表示的小数，必须显式传入 `precision = "truncate"`、`"floor"` 或 `"round"`。可表示范围取决于目标单位：`2500-01-01T00:00:00Z` 放不进纳秒，但可以解析成 `{ unit = "us" }`。

时间戳对象真正不可变：它是 const 字段的 cdata，任何字段赋值都会报错。

### 字段时间戳

除指定时间戳外，也可以写入普通时间列：

```lua
row:timestamp("event_time", qdb.time.us(1700000000123456))
row:timestamp_ns("high_precision_time", qdb.time.ns("1700000000123456789"))
```

`row:timestamp()` 根据值对象单位选择微秒或纳秒；目标 QuestDB 列的类型应与单位匹配。

`row:date()` 对应的上游函数只支持 QWP 传输（`ws::`、`udp::`），在 HTTP/TCP 的 ILP
连接上会返回 `invalid_api_call`。ILP 下要写 `DATE` 列，用 `row:timestamp_us()`，
服务端会转成毫秒保存（已在 QuestDB 10.1.0 上实测）。

服务端不会因为客户端传入了 9 位小数就自动获得纳秒列。把
`1700000000123456789` ns 写进普通 `TIMESTAMP` 后，服务端会按微秒保存并读回
`...123456Z`。因此应先确认 schema 的列类型，再选择 `time.us` 或 `time.ns`。
可以在控制台执行 `select build()` 查看服务端版本。

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

原生错误会在读取 `code`、`message` 和 `in_doubt` 后立即释放。`sender:close()` 和 `buffer:close()` 对调用方幂等，但不要依赖 GC 完成 flush；需要发送的数据必须显式 `send()` 或 `flush()`。忘记 close 的 sender 和 buffer 会被 GC 回收并释放原生资源，但里面没 flush 的行会丢失。

**flush 失败后怎么办：** 数据还留在 buffer 里，库不会替你重试，由调用方决定：

- `err.in_doubt == false`：这批数据没有写入，可以再次 `flush()`/`send()`。服务端拒绝
  （`server_flush_error`）通常重试也没用，要先用 `buffer:clear()` 丢弃才能继续写；
- `err.in_doubt == true`：数据可能已经到达服务端。只有表配置了去重（dedup）键、重复行
  无害时才应该重发；
- `sender:must_close()` 返回 `true` 时（如 TCP 的 socket 错误）sender 已不可用，
  必须关闭后新建。

sender、buffer 和 row 不应跨 LuaJIT state 或并发线程共享。一个 sender 的 buffer 只属于该 sender。

## 测试

### 离线测试

不需要 QuestDB 服务端，只要求共享库可用（`make deps` 会准备好）：

```bash
make deps        # 没有共享库时先建
make test        # 全部离线测试
make check       # deps + abi-check + test + 打印实际加载到的库
```

`make test` 覆盖：

- `2^53` 安全边界、纳秒字符串和 int64 cdata；
- RFC3339、时区偏移和负 epoch；
- 精确/截断/向下取整/舍入转换，含跨 epoch 和进位；
- `int64_t` 上下界（各构造函数都能到达边界值）、溢出、时间戳不可变；
- 平台探测与库搜索（`tests/test_platform.lua`）：库文件名随平台变化、显式路径不回退、
  拒绝缺符号的库；
- Row 生命周期（`tests/test_row.lua`）：旧 Row 不能串写、`send` 不越权、clear/close
  后失效、flush 失败保留数据、sender 能被 GC 回收；
- 共享库动态加载和当前时间函数。

### 真实写入测试

需要一个运行中、支持 `TIMESTAMP_NS` 的 QuestDB（HTTP 端口默认 `9000`）：

```bash
make integration QUESTDB_TEST_HTTP=localhost:9000
# 可选：QUESTDB_TEST_TABLE_PREFIX=luajit_it
```

每次运行都用唯一的表名建表，建表冲突直接失败，结束时只删除本次创建的表，不会动已有数据。
测试覆盖全部列类型的逐列回读、批量写入的逐行回读、指定纳秒时间戳，以及服务端拒绝后的恢复。

连不上服务端时测试**失败**而不是跳过，避免把“没跑”当成“通过”。它不在 `make test` 里。

### 已验证的组合

| 平台 | LuaJIT | 上游库 | QuestDB | 结果 |
| --- | --- | --- | --- | --- |
| macOS 27.2 / Apple Silicon | 2.1 | 7.0.0+2 (`dylib`) | 10.1.0 | 全部通过 |
| Ubuntu 24.04 / x86_64 | 2.1 | 7.0.0+2 (`so`) | 10.1.0 | 全部通过 |

其他组合（含 Windows）的文件名与搜索路径已实现，但没有实机验证。

## 开发约定

- `lua/questdb/cdef.lua` 是唯一的 FFI ABI 声明入口，改动后跑 `make abi-check`。
- 平台差异只放在 `lua/questdb/platform.lua` 和 `native.lua`，不要在别处判断
  `jit.os` 或拼库文件名。
- 当前公开入口是 `qdb.sender`、`qdb.time`；QWP、SQL reader、Arrow 和连接池仍属于后续工作。
- `time.lua` 内部禁止使用 `tonumber` 作为纳秒值的中间表示；只有明确要求安全范围内 Lua 数字时才转换。
- 新增 C API 前先核对 `build/c-questdb-client/include/questdb` 与共享库版本，
  然后补充 FFI smoke test。
- 对可能产生精度损失、资源泄漏或 borrowed memory 生命周期变化的改动，必须补测试和 README 说明。
- 改平台相关代码后，至少在 macOS 和 Linux 各跑一遍 `make check`；
  动了时间戳或写入路径再加跑 `make integration`。
