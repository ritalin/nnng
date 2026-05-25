# nnng: A wrapper for nng built on Zig’s new IO model

Provides a composable abstraction layer with Sender/Receiver capabilities.

## Requirements

Zig 0.16.0 or later
nng 1.11 (preinstalled)

Tested on macOS 15.7.4.

## Installation

Add the dependency:

```
zig fetch --save git+http://github.com/ritalin/nnng.git
```

Then include it in your build.zig:

```zig
const dep_nnng = b.dependency("nnng", .{
    .target = target,
    .optimize = optimize,
});

const exe = b.AddExecutable(.{
    ....
    .imports = &.{
        .{ .name = "nnng", .module = dep_nnng.artifact("nnng").root_module },
    }.
});
```

## Overview

`nnng` wraps `nng` with a Zig-friendly API:

- Protocols are strongly typed
- Transport (Listener/Dialer) is explicit
- Pipe model is selectable:
  - Pipe.Sync
  - Pipe.Parallel
- Message I/O is performed via Sender / Receiver

## Example (Sketch)

See the echo server and client examples:

- `examples/echo/server`
  - `blocking_server`
- `examples/echo/client`
  - `echo_oneshot`

## Linking nng

`nnng` expects `nng` to be installed on your system.

By default, it looks `NNG_PREFIX` env variable.  
If installed elsewhere, specify the prefix:

```sh
zig build -DNNG_PREFIX=/path/to/nng
```

## Notes on NNG asynchronous lifecycle behavior

NNG uses an internal asynchronous reaper for resource cleanup.
Under highly concurrent test execution with rapid teardown/recreation, this may occasionally lead to nondeterministic test failures due to lifecycle overlap.
This behavior is inherent to the underlying library design and does not affect normal application usage patterns.

## Credits

- **nng**: https://nng.nanomsg.org/
