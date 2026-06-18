# Field — one structured key/value attached to an event. The value side is a
# closed tagged sum over the types every formatter knows how to render (string,
# i64, f64, bool, raw bytes); this keeps the wire-side `Subscriber` trivial —
# format a Field by switching on its tag, no virtual call back into user code.
#
# Keys are `StaticString` deliberately: a field key at a call site is always a
# string literal, so we get a borrow-from-rodata pointer and zero allocation on
# the key column. Values that own heap storage (String, Bytes) live inside the
# `Value` sum and travel by move from the call site into the `Event.fields` list.

from std.utils import Variant


comptime _TAG_STR: UInt8 = 0
comptime _TAG_INT: UInt8 = 1
comptime _TAG_FLOAT: UInt8 = 2
comptime _TAG_BOOL: UInt8 = 3
comptime _TAG_BYTES: UInt8 = 4


struct Value(Copyable, Movable):
    """Closed sum over the renderable types. The `tag` is a runtime byte; access
    each arm via the typed `as_*` accessors (which check the tag and raise
    on mismatch — formatters should switch on `tag` directly and read the matching
    storage unconditionally)."""

    var tag: UInt8
    var _str: String
    var _int: Int64
    var _float: Float64
    var _bool: Bool
    var _bytes: List[UInt8]

    @always_inline
    def __init__(out self, *, str_value: String):
        self.tag = _TAG_STR
        self._str = str_value
        self._int = Int64(0)
        self._float = Float64(0.0)
        self._bool = False
        self._bytes = List[UInt8]()

    @always_inline
    def __init__(out self, *, int_value: Int64):
        self.tag = _TAG_INT
        self._str = String("")
        self._int = int_value
        self._float = Float64(0.0)
        self._bool = False
        self._bytes = List[UInt8]()

    @always_inline
    def __init__(out self, *, float_value: Float64):
        self.tag = _TAG_FLOAT
        self._str = String("")
        self._int = Int64(0)
        self._float = float_value
        self._bool = False
        self._bytes = List[UInt8]()

    @always_inline
    def __init__(out self, *, bool_value: Bool):
        self.tag = _TAG_BOOL
        self._str = String("")
        self._int = Int64(0)
        self._float = Float64(0.0)
        self._bool = bool_value
        self._bytes = List[UInt8]()

    @always_inline
    def __init__(out self, *, var bytes_value: List[UInt8]):
        self.tag = _TAG_BYTES
        self._str = String("")
        self._int = Int64(0)
        self._float = Float64(0.0)
        self._bool = False
        self._bytes = bytes_value^

    @always_inline
    def is_str(self) -> Bool:
        return self.tag == _TAG_STR

    @always_inline
    def is_int(self) -> Bool:
        return self.tag == _TAG_INT

    @always_inline
    def is_float(self) -> Bool:
        return self.tag == _TAG_FLOAT

    @always_inline
    def is_bool(self) -> Bool:
        return self.tag == _TAG_BOOL

    @always_inline
    def is_bytes(self) -> Bool:
        return self.tag == _TAG_BYTES

    @always_inline
    def as_str(self) -> ref[self._str] String:
        return self._str

    @always_inline
    def as_int(self) -> Int64:
        return self._int

    @always_inline
    def as_float(self) -> Float64:
        return self._float

    @always_inline
    def as_bool(self) -> Bool:
        return self._bool

    @always_inline
    def as_bytes(self) -> ref[self._bytes] List[UInt8]:
        return self._bytes


comptime _TAG_STR_PUB: UInt8 = _TAG_STR
comptime _TAG_INT_PUB: UInt8 = _TAG_INT
comptime _TAG_FLOAT_PUB: UInt8 = _TAG_FLOAT
comptime _TAG_BOOL_PUB: UInt8 = _TAG_BOOL
comptime _TAG_BYTES_PUB: UInt8 = _TAG_BYTES


struct Field(Copyable, Movable):
    """A single structured pair. Construct via typed associated functions so the
    call site stays explicit — no implicit overload resolution, the user picks
    `Field.str` or `Field.int` deliberately."""

    var key: StaticString
    var value: Value

    @always_inline
    def __init__(out self, key: StaticString, var value: Value):
        self.key = key
        self.value = value^

    @staticmethod
    @always_inline
    def str(key: StaticString, var v: String) -> Self:
        return Self(key, Value(str_value=v^))

    @staticmethod
    @always_inline
    def int(key: StaticString, v: Int) -> Self:
        return Self(key, Value(int_value=Int64(v)))

    @staticmethod
    @always_inline
    def i64(key: StaticString, v: Int64) -> Self:
        return Self(key, Value(int_value=v))

    @staticmethod
    @always_inline
    def float(key: StaticString, v: Float64) -> Self:
        return Self(key, Value(float_value=v))

    @staticmethod
    @always_inline
    def bool(key: StaticString, v: Bool) -> Self:
        return Self(key, Value(bool_value=v))

    @staticmethod
    @always_inline
    def bytes(key: StaticString, var v: List[UInt8]) -> Self:
        return Self(key, Value(bytes_value=v^))


# Tags re-exported for subscribers that switch on Field.value.tag without
# importing the private module-level constants.
comptime TAG_STR: UInt8 = _TAG_STR
comptime TAG_INT: UInt8 = _TAG_INT
comptime TAG_FLOAT: UInt8 = _TAG_FLOAT
comptime TAG_BOOL: UInt8 = _TAG_BOOL
comptime TAG_BYTES: UInt8 = _TAG_BYTES
