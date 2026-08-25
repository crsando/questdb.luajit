# QuestDB LuaJIT FFI 封装设计稿

状态：MVP 已实现；本文同时记录后续扩展设计

上游接口核对版本：`c-questdb-client` commit `8ef0219`（后续实现时应在构建配置中显式锁定版本）。

目标项目：[questdb/c-questdb-client](https://github.com/questdb/c-questdb-client)。本文定义 LuaJIT 封装的边界、时间戳语义和公共 API，并标注当前已实现与后续规划。

## 1. 目标与范围

### 1.1 目标

- 为 LuaJIT 提供一个易用、显式、不会丢失时间精度的 QuestDB 客户端。
- 通过 `ffi` 直接调用 c-questdb-client 的 C ABI，不引入 Lua C 模块。
- 默认 API 偏向逐行写入，保留 QWP 列式批量和 SQL 查询的扩展空间。
- 将连接、对象所有权、错误和时间单位封装成 Lua 习惯的接口。
- 将上游 C ABI 固定在经过验证的版本，避免直接依赖 C++ 头文件或未稳定的内部结构。

### 1.2 非目标

- 不在 Lua 层重写 QuestDB 的 ILP、QWP 或网络协议。
- 不把所有 Lua 数字都强行转换成时间戳；时间单位必须显式。
- 第一版不自行实现连接池、TLS、重试协议和 store-and-forward，这些能力由上游 C 客户端负责。
- 不在第一版承诺 Arrow/Polars 的零拷贝语义；它们可以作为后续批量 API。

## 2. 上游能力与版本策略

c-questdb-client 当前的 C 头文件主要分为：

| 能力 | 主要头文件 | 第一版策略 |
| --- | --- | --- |
| 行式 ILP 写入 | `include/questdb/ingress/line_sender.h` | MVP 支持 |
| QWP/WebSocket/UDP 写入 | `include/questdb/ingress/qwp_sender.h` | 第二阶段，优先 WebSocket |
| QWP SQL 查询与游标 | `include/questdb/egress/qwp_reader.h` | 第二阶段 |
| 连接池 | `include/questdb/client.h` | 作为可选高级 API |
| C++ wrapper | `include/questdb/**/*.hpp` | 不直接使用 |

上游库独立构建为共享库，例如 Linux 下的 `libquestdb_client.so`。Lua 模块只声明实际使用的 C 函数，使用 `ffi.load` 动态加载。`ffi.cdef` 中的声明必须由上游头文件生成或人工核对，不能复制 C++ 模板实现。

建议在 Lua 包中记录上游版本和 ABI 检查结果：

```text
questdb-luajit/
  lua/questdb/init.lua       -- 公共入口
  lua/questdb/native.lua     -- ffi.cdef、动态库加载
  lua/questdb/error.lua      -- C 错误转 Lua 错误
  lua/questdb/time.lua       -- 时间戳值对象和转换
  lua/questdb/sender.lua     -- 行式 sender/buffer
  lua/questdb/reader.lua     -- 查询和结果（第二阶段）
  tests/                     -- 纯 Lua 时间测试和 FFI smoke test
  examples/
  DESIGN.md
```

## 3. LuaJIT FFI 分层

### 3.1 native 层

`native.lua` 只做三件事：

1. 只执行一次 `ffi.cdef`。
2. 按显式路径、环境变量、平台默认名加载共享库。
3. 导出 `ffi`、库句柄和上游不透明句柄类型。

核心声明形态如下（仅示意，最终以锁定版本头文件为准）：

```lua
ffi.cdef[[
  typedef struct line_sender line_sender;
  typedef struct line_sender_buffer line_sender_buffer;
  typedef struct line_sender_error line_sender_error;

  line_sender* line_sender_from_conf(line_sender_utf8 conf,
                                     line_sender_error** err_out);
  line_sender_buffer* line_sender_buffer_new_for_sender(line_sender* sender);
  bool line_sender_buffer_table(line_sender_buffer*, line_sender_table_name,
                                line_sender_error**);
  bool line_sender_buffer_at_micros(line_sender_buffer*, int64_t,
                                    line_sender_error**);
  bool line_sender_buffer_at_nanos(line_sender_buffer*, int64_t,
                                   line_sender_error**);
  int64_t line_sender_now_micros(void);
  int64_t line_sender_now_nanos(void);
  void line_sender_buffer_free(line_sender_buffer*);
  void line_sender_close(line_sender*);
]]
```

实际声明还需要包含 UTF-8/name 结构体、字段写入函数、flush 函数和错误访问函数。不能把 `ffi.cdef` 写成“看起来能用”的简化签名：C ABI 中的参数顺序、`size_t`、`bool`、结构体布局和枚举值都必须与同一版本的头文件一致。

### 3.2 Lua 对象层

建议的所有权关系：

```text
client/sender -> buffer -> 当前行
```

- `sender:buffer()` 创建一个 buffer；buffer 只属于创建它的 sender。
- Lua wrapper 在对象上维护 `closed` 状态，因此 `buffer:close()` 和 `sender:close()` 对调用方幂等；底层 `line_sender_close` 本身并不保证重复调用安全。
- 每个 C 指针同时支持显式释放和 `ffi.gc` 兜底；显式释放后必须用 `ffi.gc(ptr, nil)` 解除 finalizer。
- finalizer 只做不阻塞的释放，不能在 GC 回调中 flush、重试、等待网络或抛出 Lua 错误。
- sender、buffer 和 cursor 均按上游约定单线程使用；不要在多个 LuaJIT state 之间共享 Lua 对象。

推荐把 C 错误转成结构化 Lua 错误，而不是直接返回裸布尔值：

```lua
local ok, err = buffer:at(timestamp)
if not ok then
  -- err.code、err.message、err.native_code
end
```

也可以提供 `assert_ok(...)` 风格的便利函数。错误对象必须在读取 message/code 后立即调用上游的 `line_sender_error_free`，不能让 C 错误指针长期留在 Lua 表中。

## 4. 推荐的公共 API（MVP）

```lua
local qdb = require "questdb"

local sender = qdb.sender {
  conf = "http::addr=localhost:9000;",
  -- lib = "/opt/questdb/lib/libquestdb_client.so", -- 可选
}

local row = sender:row("trades")
-- 假设 trades 的指定时间列是 TIMESTAMP_NANOS
row:symbol("sym", "BTC-USD")
row:double("price", 42000.25)
row:int64("qty", 2)
row:at(qdb.time.ns("1700000000123456789"))
assert(row:send())

sender:close()
```

API 约定：

- `sender:row(table)` 创建新行；`symbol` 必须先于普通字段，符合 ILP 顺序约束。
- `row:at(timestamp)` 要求传入带单位的时间戳对象；不接受无单位裸数字。
- `row:at_now()` 显式选择“由 QuestDB 到达时赋值”，与客户端当前时间完全不同。
- `row:send()` 在内部完成当前行结束、flush 策略和错误转换。高吞吐模式另提供 `buffer`，允许多行后显式 `flush()`。
- `row:string`、`row:bool`、`row:int64`、`row:double` 等方法只负责类型映射，不通过 Lua 字符串拼接伪造 ILP。

第二阶段可以补充：

```lua
local db = qdb.connect { conf = "ws://localhost:9000" }
local s = db:borrow_sender()
local chunk = s:chunk()
chunk:column("ts", qdb.time.column_ns(values))
chunk:at_ns(timestamps)
s:flush_and_wait(chunk, "ok")

local reader = db:borrow_reader()
local cursor = reader:query("select ts, price from trades where ts > $1")
cursor:bind(1, qdb.time.us(1700000000000000))
for row in cursor:rows() do
  -- row.ts 是带单位的 timestamp 对象；NULL 转为 nil
end
```

## 5. 时间戳模型（重点）

### 5.1 QuestDB 的三种相关类型

QuestDB 保存的是 Unix epoch UTC 整数，不保存时区。单位由列类型决定：

| QuestDB 类型 | 整数单位 | c-questdb-client 相关入口 | LuaJIT 推荐表示 |
| --- | --- | --- | --- |
| `DATE` | 毫秒（ms） | `line_sender_buffer_column_date`、`bind_date_millis` | `int64_t`；普通当前日期数字也安全 |
| `TIMESTAMP` | 微秒（us） | `*_column_ts_micros`、`*_at_micros`、`bind_timestamp_micros` | 带 `us` 单位的 `int64_t`，可在安全范围内接受整数 number |
| `TIMESTAMP_NANOS` | 纳秒（ns） | `*_column_ts_nanos`、`*_at_nanos`、`bind_timestamp_nanos` | 必须优先使用 `int64_t` cdata 或十进制字符串 |

行式 API 的 `at_micros`/`at_nanos` 和 QWP 的 `qwp_chunk_at_micros`/`qwp_chunk_at_nanos` 都已经把单位写在函数名中。封装不能把一个统一的 `number timestamp` 直接传给两者，否则调用方很容易把微秒当成纳秒或反过来。

### 5.1.1 数字格式与文本格式的边界

在 C 客户端的写入和查询 ABI 中，时间戳是有符号 64 位 epoch 整数，不是格式化字符串。RFC3339/ISO-8601 只应出现在 Lua 的输入输出便利层：

- 输入允许 `2023-11-14T22:13:20.123456789Z`，也允许带偏移的 `+08:00`；解析后立即归一化为 UTC epoch 整数。
- 输出默认使用 UTC 的 `Z` 后缀，并按值对象的单位输出 3、6 或 9 位小数；不把 `number` 作为中间格式。
- `TIMESTAMP` 默认输出 6 位小数，`TIMESTAMP_NANOS` 默认输出 9 位，`DATE` 默认输出 3 位。若末尾全为零，可以提供 `trim = true` 的展示选项，但不能改变原始单位。
- 不接受带指数的数字字符串、没有单位的裸 epoch 字符串或依赖本地时区的日期文本。

这样可以把“展示格式”和“存储精度”分开：字符串看起来只有 3 位小数，不代表数据库列就只有毫秒精度；反之，向 `TIMESTAMP` 写入纳秒值也不会因为文本保留 9 位就自动获得纳秒列。

### 5.2 为什么 LuaJIT number 不能承载纳秒

LuaJIT 默认 `number` 是 IEEE-754 double。整数只有在绝对值不超过 `2^53` 时才保证逐个可表示：

```text
2^53 = 9,007,199,254,740,992
```

以当前日期为例：

- epoch ms 约 `1.7e12`，远小于 `2^53`，可精确表示；
- epoch us 约 `1.7e15`，仍小于 `2^53`，通常可精确表示；
- epoch ns 约 `1.7e18`，远大于 `2^53`，会被舍入。

因此下面的代码不能作为纳秒 API：

```lua
-- 错误：字面量先变成 double，之后再转 int64 已经丢精度
row:at(qdb.time.ns(1700000000123456789))
```

应改成十进制字符串或 cdata：

```lua
row:at(qdb.time.ns("1700000000123456789"))
-- 已有的 int64_t cdata（例如 time.now_ns():raw()）也可以直接传入
row:at(qdb.time.ns(qdb.time.now_ns():raw()))
```

`time.ns()` 在收到不安全的 Lua number 时应直接报错，不能静默转换。为减少调用方负担，提供不需要写大整数字面量的构造方式：

```lua
qdb.time.from_unix(1700000000, 123456789, "ns")
qdb.time.parse_rfc3339("2023-11-14T22:13:20.123456789Z")
qdb.time.now_ns()
```

其中秒数、纳秒余数分别校验范围，再用 `int64_t` 运算合成 epoch ns。十进制字符串也必须由封装按字符分段解析后合成 cdata；不能直接依赖 `ffi.new("int64_t", text)`，LuaJIT FFI 不接受这种字符串转换。

### 5.3 时间值对象

`time.lua` 建议实现不可变值对象：

```lua
local t = qdb.time.ns("1700000000123456789")
t:unit()       -- "ns"
t:raw()        -- ffi.new("int64_t", ...)
t:to_string()  -- "2023-11-14T22:13:20.123456789Z"
t:to_us()      -- 仅在可精确转换时成功
```

内部结构应类似 `{ unit = "ns", value = int64_cdata }`，而不是 `{ value = tonumber(...) }`。公开构造函数：

- `time.ms(value)`、`time.us(value)`、`time.ns(value)`：单位显式。
- `time.from_unix(seconds, fraction, unit)`：避免大整数 number。
- `time.parse_rfc3339(text, opts)`：纯整数解析，支持最多 9 位小数和 `Z`/显式偏移。
- `time.now_ms/us/ns()`：分别返回带单位对象。
- `time.is_timestamp(value)`：用于 API 边界检查。

### 5.4 精度转换规则

默认策略是“宁可失败，不要静默丢精度”：

```lua
local ns = qdb.time.ns("1700000000123456789")
ns:to_us()                         -- error：余数 789 不能精确表示
ns:to_us { mode = "truncate" }    -- 明确允许截断
ns:to_us { mode = "round" }       -- 明确允许舍入
```

建议规则：

1. 升精度（ms -> us -> ns）只做整数乘法，检查 `int64_t` 溢出。
2. 降精度默认要求余数为零。
3. `truncate` 的行为要写入文档并固定为“向零截断”；负 epoch 的业务若需要区间下界，应显式使用 `floor`。
4. `round` 采用对称的整数舍入（半数远离零），不经过 double。
5. `parse_rfc3339` 解析出 7--9 位小数时，如果目标单位是 us，默认报错；只有设置 `precision = "truncate"` 或 `"round"` 才转换。
6. 不允许把 `DATE` 自动当成 `TIMESTAMP`；毫秒、微秒、纳秒的语义必须由调用方选择。

负 epoch 必须使用数学上的“商 + 非负余数”进行格式化和拆分。例如 `-1 ns` 应格式化为 `1969-12-31T23:59:59.999999999Z`，不能因为 Lua/C 的向零除法而显示成 `1970-01-01T00:00:00.-1Z`。

### 5.5 范围与 NULL

三个类型在 C ABI 中都以有符号 `int64_t` 传输，范围是 `[-2^63, 2^63-1]`。纳秒精度的整数范围大约覆盖 1677--2262 年；微秒和毫秒的理论时间范围更大，但仍应在构造和单位乘法时做溢出检查。

指定 timestamp（`at_*`）在协议中不能为 NULL。可空的查询列应由 `qwp_reader_column_data.validity` 判断，Lua 层统一映射为 `nil`，不要把 `INT64_MIN` 当作通用的 Lua NULL 值。写入普通字段时，`nil` 是否表示 NULL 由对应的字段 API 明确规定，不能隐式把 `0` 当 NULL。

### 5.6 查询结果与 bind

查询结果的列 kind 必须保留单位：

- `qwp_reader_column_kind_timestamp` -> `time.us(raw_i64)`；
- `qwp_reader_column_kind_timestamp_nanos` -> `time.ns(raw_i64)`；
- `DATE` -> `time.ms(raw_i64)`。

绑定参数使用对应的 C 函数：`bind_timestamp_micros`、`bind_timestamp_nanos`、`bind_date_millis`。`bind(1, timestamp)` 根据值对象单位分派；如果 SQL 参数类型要求另一精度，调用方必须先显式 `to_us`/`to_ns`。

## 6. 错误、生命周期和线程

- 所有 C 返回值都先检查，再读取错误对象；C 错误码同时保留 `native_code` 和可读 message。
- `close()` 幂等，close 后的方法统一返回带 `code = "closed"` 的本地错误。
- `ffi.gc` 只作泄漏兜底；需要网络完成或 ACK 的应用必须显式 `flush`/`wait`，不能依赖 GC。
- buffer 中 C API 若借用 Lua 字符串或数组，Lua wrapper 必须让其活到本次 C 调用/flush 返回；批量 QWP API 的 borrowed data 则要绑定到 chunk 生命周期。
- LuaJIT VM 本身不建议跨线程共享对象；并发写入使用每线程/每 Lua state 的 sender 或上游 pool borrow。

## 7. 测试计划

### 7.1 纯 Lua 时间测试

- `2^53-1`、`2^53`、`2^53+1` 的安全整数检查。
- 当前 epoch 的 ms/us 精确 round-trip。
- 纳秒十进制字符串、`int64_t` cdata、`from_unix` 三种输入的相同结果。
- 9 位小数的 RFC3339 parse/format round-trip。
- `ns -> us` 的 exact/truncate/round，包含负数和半单位。
- `int64_t` 上下界及各单位乘法溢出。
- `-1 ns`、1970 epoch、闰年、时区偏移和非法日期。
- NULL 不被错误转为 `0` 或 `INT64_MIN`。

### 7.2 ABI/集成测试

- 用最小配置连接本地 QuestDB，写入 `DATE`、`TIMESTAMP`、`TIMESTAMP_NANOS` 三列并查询原始值。
- 分别验证 `at_micros`、`at_nanos`、`at_now` 的差异。
- 验证 query bind 的 us/ns 分派和 NULL 列读取。
- 检查 buffer/sender/cursor 显式 close、GC 兜底和重复 close。
- 在 ASAN/Valgrind 下运行 FFI smoke test，重点检查 error 指针和 borrowed buffer 生命周期。

## 8. 实施阶段

1. **MVP**：锁定上游版本；实现 native/error/time；实现 ILP 行式 sender、显式时间值和基础测试。
2. **批量写入**：增加 QWP chunk，先支持固定宽度标量和 timestamp 列；明确 borrowed memory 生命周期。
3. **查询**：实现 reader、bind、游标和带单位的结果值；默认提供物化行迭代器，再提供高级 batch view。
4. **高级能力**：连接池、ACK 等级、TLS/认证配置、Arrow/数组和性能优化。

第一版验收标准是：任何纳秒时间戳都不会先经过 Lua double；API 能从类型/函数名上区分 ms、us、ns；对不安全输入和隐式精度损失直接报错；关闭对象不会泄漏 C 资源。
