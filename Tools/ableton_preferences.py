"""Conservative, surgical label edits for Live's macOS Preferences.cfg.

The format is undocumented. Read the embedded schema, recognize one contiguous
CoreAudioDevice list, and replace only existing UTF-16 string spans. Never
reserialize the rest of the file or invent device/channel/list entries.
"""
from dataclasses import dataclass
import re
import struct


class FormatError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise FormatError(message)


def tag(name):
    encoded = name.encode("ascii")
    return bytes((0, len(encoded))) + encoded


def encode_string(value):
    require(isinstance(value, str) and "\0" not in value, "Invalid channel name")
    raw = value.encode("utf-16le")
    require(len(raw) <= 32768, "Channel name is too long")
    return struct.pack("<I", len(raw) // 2) + raw


SCHEMAS = {
    "AudioLatencyFloat": [("Value", 0x12)],
    "AudioChannelNames": [("MonoL", 0x14), ("MonoR", 0x14), ("Stereo", 0x14)],
    "AudioChannelData": [("NumPhysicalChannels", 0x11), ("MonoArray", 0x50),
                         ("StereoArray", 0x50), ("Names", "List<AudioChannelNames>")],
    "CoreAudioDevice": [("BufferSize", "AudioLatencyFloat"), ("InChannelData", "AudioChannelData"),
                        ("OutChannelData", "AudioChannelData"), ("ClockSourceIndex", 0x11),
                        ("HistoryOpenCount", 0x11), ("UniqueId", 0x14)],
    "List<AudioChannelNames>": None,
}


@dataclass(frozen=True)
class TextSpan:
    start: int
    end: int
    value: str


class Reader:
    def __init__(self, data, offset=0):
        self.data, self.pos = data, offset

    def take(self, count):
        require(0 <= count <= len(self.data) - self.pos, "Truncated preferences")
        value = self.data[self.pos:self.pos + count]
        self.pos += count
        return value

    def integer(self):
        return struct.unpack("<I", self.take(4))[0]

    def kind(self):
        code = self.take(1)[0]
        return self.take(self.take(1)[0]).decode("ascii") if code == 0 else code

    def string(self):
        start = self.pos
        size = self.integer()
        require(size <= 16384, "Unexpected string length")
        value = self.take(size * 2).decode("utf-16le")
        require("\0" not in value, "Embedded null in preferences string")
        return TextSpan(start, self.pos, value)

    def flags(self):
        count = self.integer()
        require(count <= 4096, "Unexpected activator count")
        value = self.take(count)
        require(set(value) <= {0, 1}, "Invalid channel activators")
        return value


@dataclass
class Channels:
    count: int
    mono: bytes
    stereo: bytes
    next_id: int
    rows: list


@dataclass
class Device:
    uid: str
    index: int
    start: int
    end: int
    inputs: Channels
    outputs: Channels


def read_channels(reader):
    count = reader.integer()
    require(count <= 4096, "Unexpected physical channel count")
    mono, stereo = reader.flags(), reader.flags()
    next_id = reader.integer()
    rows, ids = [], set()
    while True:
        name = reader.kind()
        if name == "":
            break
        require(name == "AudioChannelNames", "Unexpected channel-list object")
        index = reader.integer()
        require(index < next_id and index not in ids, "Invalid channel-list ID")
        ids.add(index)
        rows.append((index, [reader.string() for _ in range(3)]))
        require(len(rows) <= 4096, "Too many channel-name rows")
    return Channels(count, mono, stereo, next_id, rows)


def read_schema(reader):
    require(reader.take(5) == b"\xab\x1eVx\x05", "Unsupported Preferences.cfg format/version")
    reader.take(4)  # Preserve Live's producer metadata verbatim.
    require(reader.kind() == "LivePreferences", "Not a Live preferences file")
    count = reader.integer()
    require(1 <= count <= 1024, "Unexpected schema count")
    schemas = {}
    for _ in range(count):
        name = reader.kind()
        require(isinstance(name, str) and name and name not in schemas, "Invalid schema name")
        size = reader.integer()
        fields = None
        if size != 0xFFFFFFFF:
            require(size <= 4096, "Unexpected schema field count")
            fields = [(reader.string().value, reader.kind()) for _ in range(size)]
        schemas[name] = fields
    for name, expected in SCHEMAS.items():
        require(name in schemas and schemas[name] == expected, f"Unsupported {name} schema; no file written")


def parse(data):
    require(len(data) <= 32 * 1024 * 1024, "Preferences file exceeds supported size")
    reader = Reader(data)
    read_schema(reader)
    marker = tag("CoreAudioDevice")
    start = data.find(marker, reader.pos)
    require(start >= reader.pos + 4, "No saved Core Audio device list; select the device in Live first")
    reader.pos = start - 4
    next_id = reader.integer()
    devices, ids = {}, set()
    while True:
        start = reader.pos
        name = reader.kind()
        if name == "":
            break
        require(name == "CoreAudioDevice", "Unrecognized Core Audio device-list layout")
        index = reader.integer()
        require(index < next_id and index not in ids, "Invalid device-list ID")
        ids.add(index)
        reader.take(4)  # AudioLatencyFloat
        inputs, outputs = read_channels(reader), read_channels(reader)
        reader.take(8)  # ClockSourceIndex and HistoryOpenCount
        uid = reader.string().value
        require(uid and uid not in devices, "Empty or duplicate device UID")
        devices[uid] = Device(uid, index, start, reader.pos, inputs, outputs)
        require(len(devices) <= 4096, "Too many saved audio devices")
    require(data.find(marker, reader.pos) == -1, "Ambiguous additional Core Audio device data")
    return devices


def active_rows(channels, count):
    # Live rounds one-channel devices to a pair. Do not synthesize that missing
    # channel or change its settings; unsupported widths are rejected explicitly.
    require(count % 2 == 0, "Odd channel counts are not supported by this format adapter")
    require(channels.count == count, "Core Audio and Live channel counts differ; open and quit Live once to refresh")
    pairs = count // 2
    require(len(channels.mono) == pairs and len(channels.stereo) == pairs and len(channels.rows) >= pairs,
            "Saved channel layout is incomplete; open and quit Live once to refresh")
    return channels.rows[:pairs]


def pair_labels(left, right):
    # Match a separate L/R suffix, optionally before a shared qualifier such as
    # "(analog)". Never infer a stereo pair from two unrelated channel names.
    pattern = r"(.+?)\s+([LR])((?:\s+\([^()\r\n]*\))?)"
    l = re.fullmatch(pattern, left, re.IGNORECASE)
    r = re.fullmatch(pattern, right, re.IGNORECASE)
    if (l and r and l[2].upper() == "L" and r[2].upper() == "R"
            and l[1] == r[1] and l[3] == r[3]):
        return ["", "", (l[1] + l[3]).strip()]
    l = re.fullmatch(r"(.+?\s+)([0-9]+)", left)
    r = re.fullmatch(r"(.+?\s+)([0-9]+)", right)
    if l and r and l[1] == r[1] and left != right:
        return [left, right, f"{left}/{r[2]}"]
    return [left, right, left if left == right else f"{left} / {right}"]


def patch(data, uid, names=None, restore=None):
    devices = parse(data)
    require(uid in devices, f"Device UID {uid!r} is not saved in Live")
    device = devices[uid]
    previous = None
    if restore is not None:
        previous = parse(restore).get(uid)
        require(previous is not None, "Backup has no matching device UID")
    require((names is None) != (restore is None), "Supply current names or a backup")
    edits, changes = [], []
    for direction in ("inputs", "outputs"):
        channels = getattr(device, direction)
        if previous:
            old = getattr(previous, direction)
            rows = active_rows(channels, old.count)
            desired = [[span.value for span in spans] for _, spans in active_rows(old, old.count)]
        else:
            values = names[direction]
            require(isinstance(values, list) and all(isinstance(v, str) for v in values), "Invalid Core Audio name list")
            rows = active_rows(channels, len(values))
            desired = [pair_labels(left, right)
                       for left, right in zip(values[::2], values[1::2])]
        for pair, ((_, spans), target) in enumerate(zip(rows, desired)):
            for label, span, value in zip((f"mono {2*pair+1}", f"mono {2*pair+2}", f"stereo {2*pair+1}/{2*pair+2}"), spans, target):
                if span.value != value:
                    edits.append((span.start, span.end, encode_string(value)))
                    changes.append((direction, label, span.value, value))
    output = data
    for start, end, value in sorted(edits, reverse=True):
        output = output[:start] + value + output[end:]
    # Parsing again catches bad lengths/boundaries. Replacing the edited strings
    # with their originals must reproduce every byte, including unrelated data.
    reparsed = parse(output)[uid]
    inverse = []
    for direction in ("inputs", "outputs"):
        before, after = getattr(device, direction), getattr(reparsed, direction)
        require((before.count, before.mono, before.stereo, before.next_id) ==
                (after.count, after.mono, after.stereo, after.next_id), "Non-label channel data changed")
        require(len(before.rows) == len(after.rows), "Channel list changed")
        for (old_id, old_spans), (new_id, new_spans) in zip(before.rows, after.rows):
            require(old_id == new_id, "Channel IDs changed")
            inverse += [(new.start, new.end, encode_string(old.value)) for old, new in zip(old_spans, new_spans)]
    recovered = output
    for start, end, value in sorted(inverse, reverse=True):
        recovered = recovered[:start] + value + recovered[end:]
    require(recovered == data, "Changes escaped the channel-name fields")
    return output, changes
