# 0.1.4

* Update `RawBson.into` to return a fully copy of the data to avoid issues with callers deinitializing the underlying data.

# 0.1.3

* correct `RawBson.into` issue with optional typed fields when present

# 0.1.2

* add `RawBson.{into,from}` to support converting RawBson to and from custom types
* add `Reader.readInto` and `Writer.writeFrom` to support adapting to custom types
* introduce `bson.Owned` type which `Reader` now returns. this allows returned bson to outlive the `Reader` instance that produced it

# 0.1.1

* Upgrade to zig 0.13.0. No breaking changes.

# 0.1.0

* basic read/write functionality works
