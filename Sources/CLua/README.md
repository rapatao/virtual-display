# CLua

Lua 5.4.8, vendored verbatim from https://www.lua.org/ftp/lua-5.4.8.tar.gz
(sha256 `4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae`), MIT licensed:
see `README.lua`.

Only two things differ from the upstream `src/` directory:

- `lua.c`, `luac.c` and `onelua.c` are removed. They define `main`.
- The four public headers live in `include/` with a hand-written `module.modulemap`, and
  the internal headers sit next to the `.c` files. SwiftPM otherwise builds an umbrella
  module out of every header in `include/`, and Lua's internal headers are not meant to be
  included on their own.

To upgrade: drop in a new `src/`, repeat those two steps, run `swift test`.

No JIT, so nothing here needs a hardened runtime exception or an extra entitlement.
