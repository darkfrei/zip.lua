-- zip.lua
-- pure lua/luajit zip archive module with zlib deflate
-- compatible with lua 5.1/luajit
-- version 2025-11-27
-- https://github.com/darkfrei/zip.lua

-- the FFI (Foreign Function Interface) in LuaJIT is a powerful 
-- feature that allows Lua code to directly call C functions 
-- and manipulate C data structures without writing binding code in C
local ffi = require("ffi")

-- bitwise operations (luajit built-in)
local band = bit.band
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

----------------------
-- constants
----------------------

-- zlib constants
local Z_OK = 0
local Z_STREAM_END = 1
local Z_DEFLATED = 8
local Z_DEFAULT_COMPRESSION = -1
local Z_FINISH = 4
local Z_NO_FLUSH = 0

-- zip signatures
local SIG_LOCAL_FILE_HEADER = "\x50\x4b\x03\x04"
local SIG_CENTRAL_DIR_HEADER = "\x50\x4b\x01\x02"
local SIG_END_OF_CENTRAL_DIR = "\x50\x4b\x05\x06"

-- zip compression methods
local COMPRESSION_STORED = 0
local COMPRESSION_DEFLATE = 8

-- zip structure sizes and offsets
local VERSION_NEEDED = 20
local VERSION_MADE_BY = 20
local GENERAL_PURPOSE_FLAG = 0
local CHUNK_SIZE = 32768
local EOCD_MAX_SEARCH = 65536
local MIN_DOS_YEAR = 1980

-- numeric constants
local UINT16_MAX = 0x10000
local UINT32_MAX = 0x100000000

-- zlib parameters
local ZLIB_WINDOW_BITS = -15 -- raw deflate
local ZLIB_MEM_LEVEL = 8
local ZLIB_STRATEGY = 0

----------------------
-- zlib ffi bindings
----------------------

-- try to load zlib from common library names
local function loadZlib()
	local names = {"z", "zlib", "libz", "zlib1", "zlib1.dll", "z.dll"}
	for _, name in ipairs(names) do
		local ok, lib = pcall(ffi.load, name)
		if ok then return lib end
	end
	error("cannot load zlib library")
end

local zlib = loadZlib()

ffi.cdef[[
typedef unsigned char Bytef;
typedef unsigned int uInt;
typedef unsigned long uLong;
typedef void *voidpf;

typedef struct z_stream_s {
	Bytef *next_in;
	uInt avail_in;
	uLong total_in;

	Bytef *next_out;
	uInt avail_out;
	uLong total_out;

	const char *msg;
	void *state;

	voidpf zalloc;
	voidpf zfree;
	voidpf opaque;

	int data_type;
	uLong adler;
	uLong reserved;
	} z_stream;

const char * zlibVersion();

int deflateInit2_(z_stream *strm, int level, int method, int windowBits,
	int memLevel, int strategy, const char *version, int stream_size);
int deflate(z_stream *strm, int flush);
int deflateEnd(z_stream *strm);

int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);

uLong crc32(uLong crc, const Bytef *buf, uInt len);
]]

local ZLIB_VERSION = ffi.string(zlib.zlibVersion())

----------------------
-- utility functions
----------------------

-- calculate crc32 checksum
local function crc32(data, crc)
	crc = crc or 0
	if #data == 0 then return crc end

	local buf = ffi.new("unsigned char[?]", #data)
	ffi.copy(buf, data, #data)
	local res = zlib.crc32(crc, buf, #data)
	return tonumber(res)
end

-- convert unix timestamp to dos date/time format
local function toDosDateTime(timestamp)
	local date = os.date("*t", timestamp or os.time())
	local year = date.year
	if year < MIN_DOS_YEAR then year = MIN_DOS_YEAR end

	local dosDate = bor(lshift(year - MIN_DOS_YEAR, 9), lshift(date.month, 5), date.day)
	local dosTime = bor(lshift(date.hour, 11), lshift(date.min, 5), math.floor(date.sec / 2))
	return dosTime, dosDate
end

-- write little-endian 16-bit integer
local function writeUInt16(n)
	n = n % UINT16_MAX
	return string.char(band(n, 0xFF), band(rshift(n, 8), 0xFF))
end

-- write little-endian 32-bit integer
local function writeUInt32(n)
	n = n % UINT32_MAX
	return string.char(
		band(n, 0xFF),
		band(rshift(n, 8), 0xFF),
		band(rshift(n, 16), 0xFF),
		band(rshift(n, 24), 0xFF)
	)
end

-- read little-endian 16-bit integer
local function readUInt16(data, offset)
	offset = offset or 1
	local a, b = data:byte(offset, offset + 1)
	return bor(a or 0, lshift(b or 0, 8))
end

-- read little-endian 32-bit integer
local function readUInt32(data, offset)
	offset = offset or 1
	local a, b, c, d = data:byte(offset, offset + 3)
	return bor(a or 0, lshift(b or 0, 8), lshift(c or 0, 16), lshift(d or 0, 24))
end

----------------------
-- compression functions
----------------------

-- compress data using raw deflate (windowBits = -15)
local function compress(data)
	if #data == 0 then return "" end

	local stream = ffi.new("z_stream")
	stream.zalloc = nil
	stream.zfree = nil
	stream.opaque = nil

	-- copy input into c buffer
	local inbuf = ffi.new("unsigned char[?]", #data)
	ffi.copy(inbuf, data, #data)
	stream.next_in = inbuf
	stream.avail_in = #data

	local ret = zlib.deflateInit2_(stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 
		ZLIB_WINDOW_BITS, ZLIB_MEM_LEVEL, ZLIB_STRATEGY, ZLIB_VERSION, ffi.sizeof(stream))
	if ret ~= Z_OK then error("deflateInit2_ failed: " .. ret) end

	local chunks = {}
	local outbuf = ffi.new("unsigned char[?]", CHUNK_SIZE)

	repeat
		stream.next_out = outbuf
		stream.avail_out = CHUNK_SIZE

		ret = zlib.deflate(stream, Z_FINISH)
		if ret ~= Z_OK and ret ~= Z_STREAM_END then
			zlib.deflateEnd(stream)
			error("deflate failed: " .. ret)
		end

		local have = CHUNK_SIZE - tonumber(stream.avail_out)
		if have > 0 then
			table.insert(chunks, ffi.string(outbuf, have))
		end
	until ret == Z_STREAM_END

	zlib.deflateEnd(stream)
	return table.concat(chunks)
end

-- decompress raw deflate data
local function decompress(data, expectedSize)
	if #data == 0 then return "" end

	local stream = ffi.new("z_stream")
	stream.zalloc = nil
	stream.zfree = nil
	stream.opaque = nil

	local inbuf = ffi.new("unsigned char[?]", #data)
	ffi.copy(inbuf, data, #data)
	stream.next_in = inbuf
	stream.avail_in = #data

	local ret = zlib.inflateInit2_(stream, ZLIB_WINDOW_BITS, ZLIB_VERSION, ffi.sizeof(stream))
	if ret ~= Z_OK then error("inflateInit2_ failed: " .. ret) end

	local chunks = {}
	local chunkSize = expectedSize and math.min(expectedSize, CHUNK_SIZE) or CHUNK_SIZE
	local outbuf = ffi.new("unsigned char[?]", chunkSize)

	repeat
		stream.next_out = outbuf
		stream.avail_out = chunkSize

		ret = zlib.inflate(stream, Z_NO_FLUSH)
		if ret ~= Z_OK and ret ~= Z_STREAM_END then
			zlib.inflateEnd(stream)
			error("inflate failed: " .. ret)
		end

		local have = chunkSize - tonumber(stream.avail_out)
		if have > 0 then
			table.insert(chunks, ffi.string(outbuf, have))
		end
	until ret == Z_STREAM_END

	zlib.inflateEnd(stream)
	return table.concat(chunks)
end

----------------------
-- zip archive class
----------------------

local zip = {}
zip.__index = zip

-- create a new zip archive
local function new(comment)
	return setmetatable({
			entries = {},
			comment = comment or ""
			}, zip)
end

-- add a file to the archive
function zip:addFile(filename, data, shouldCompress)
	if shouldCompress == nil then shouldCompress = true end

	local entry = {
		filename = filename,
		data = data,
		uncompressed_size = #data,
		crc32 = crc32(data)
	}

	if shouldCompress then
		entry.compressed_data = compress(data)
		entry.compressed_size = #entry.compressed_data
		entry.compression_method = COMPRESSION_DEFLATE
	else
		entry.compressed_data = data
		entry.compressed_size = #data
		entry.compression_method = COMPRESSION_STORED
	end

	table.insert(self.entries, entry)
end

-- generate zip archive binary data
function zip:write()
	local parts = {}
	local offset = 0
	local centralDirParts = {}

	local dosTime, dosDate = toDosDateTime()

	-- write local file headers and data
	for _, entry in ipairs(self.entries) do
		local localHeader = {}
		table.insert(localHeader, SIG_LOCAL_FILE_HEADER)
		table.insert(localHeader, writeUInt16(VERSION_NEEDED))
		table.insert(localHeader, writeUInt16(GENERAL_PURPOSE_FLAG))
		table.insert(localHeader, writeUInt16(entry.compression_method))
		table.insert(localHeader, writeUInt16(dosTime))
		table.insert(localHeader, writeUInt16(dosDate))
		table.insert(localHeader, writeUInt32(entry.crc32))
		table.insert(localHeader, writeUInt32(entry.compressed_size))
		table.insert(localHeader, writeUInt32(entry.uncompressed_size))
		table.insert(localHeader, writeUInt16(#entry.filename))
		table.insert(localHeader, writeUInt16(0)) -- extra field length
		table.insert(localHeader, entry.filename)

		local headerData = table.concat(localHeader)
		table.insert(parts, headerData)
		table.insert(parts, entry.compressed_data)

		entry.local_header_offset = offset
		offset = offset + #headerData + entry.compressed_size

		-- build central directory entry
		local cd = {}
		table.insert(cd, SIG_CENTRAL_DIR_HEADER)
		table.insert(cd, writeUInt16(VERSION_MADE_BY))
		table.insert(cd, writeUInt16(VERSION_NEEDED))
		table.insert(cd, writeUInt16(GENERAL_PURPOSE_FLAG))
		table.insert(cd, writeUInt16(entry.compression_method))
		table.insert(cd, writeUInt16(dosTime))
		table.insert(cd, writeUInt16(dosDate))
		table.insert(cd, writeUInt32(entry.crc32))
		table.insert(cd, writeUInt32(entry.compressed_size))
		table.insert(cd, writeUInt32(entry.uncompressed_size))
		table.insert(cd, writeUInt16(#entry.filename))
		table.insert(cd, writeUInt16(0)) -- extra field length
		table.insert(cd, writeUInt16(0)) -- file comment length
		table.insert(cd, writeUInt16(0)) -- disk number start
		table.insert(cd, writeUInt16(0)) -- internal file attributes
		table.insert(cd, writeUInt32(0)) -- external file attributes
		table.insert(cd, writeUInt32(entry.local_header_offset))
		table.insert(cd, entry.filename)

		table.insert(centralDirParts, table.concat(cd))
	end

	-- write central directory
	local cdOffset = offset
	local cdData = table.concat(centralDirParts)
	table.insert(parts, cdData)

	-- write end of central directory record
	local eocd = {}
	table.insert(eocd, SIG_END_OF_CENTRAL_DIR)
	table.insert(eocd, writeUInt16(0)) -- number of this disk
	table.insert(eocd, writeUInt16(0)) -- disk where central directory starts
	table.insert(eocd, writeUInt16(#self.entries)) -- entries on this disk
	table.insert(eocd, writeUInt16(#self.entries)) -- total entries
	table.insert(eocd, writeUInt32(#cdData)) -- size of central directory
	table.insert(eocd, writeUInt32(cdOffset)) -- offset of central directory
	table.insert(eocd, writeUInt16(#self.comment))
	table.insert(eocd, self.comment)

	table.insert(parts, table.concat(eocd))

	return table.concat(parts)
end

-- save archive to file
function zip:save(filename)
	local file = assert(io.open(filename, "wb"), "cannot open file: " .. filename)
	file:write(self:write())
	file:close()
end

-- read zip archive from binary data
local function read(data)
	-- find end of central directory record
	local startSearch = math.max(1, #data - EOCD_MAX_SEARCH)
	local eocdPos = data:find(SIG_END_OF_CENTRAL_DIR, startSearch, true)
	if not eocdPos then error("eocd signature not found") end

	-- parse eocd
	local entriesCount = readUInt16(data, eocdPos + 10)
	local cdSize = readUInt32(data, eocdPos + 12)
	local cdOffset = readUInt32(data, eocdPos + 16)
	local commentLength = readUInt16(data, eocdPos + 20)

	local comment = ""
	if commentLength > 0 then
		comment = data:sub(eocdPos + 22, eocdPos + 21 + commentLength)
	end

	-- create archive
	local archive = new(comment)

	-- parse central directory
	local pos = cdOffset + 1

	for i = 1, entriesCount do
		local sig = data:sub(pos, pos + 3)
		if sig ~= SIG_CENTRAL_DIR_HEADER then
			error("invalid central directory signature")
		end

		local compressionMethod = readUInt16(data, pos + 10)
		local crc = readUInt32(data, pos + 16)
		local compressedSize = readUInt32(data, pos + 20)
		local uncompressedSize = readUInt32(data, pos + 24)
		local fileNameLen = readUInt16(data, pos + 28)
		local extraLen = readUInt16(data, pos + 30)
		local commentLen = readUInt16(data, pos + 32)
		local localHeaderOffset = readUInt32(data, pos + 42)

		local filename = data:sub(pos + 46, pos + 45 + fileNameLen)

		-- read local header to find data offset
		local lhPos = localHeaderOffset + 1
		local lhSig = data:sub(lhPos, lhPos + 3)
		if lhSig ~= SIG_LOCAL_FILE_HEADER then
			error("invalid local header signature")
		end

		local lhNameLen = readUInt16(data, lhPos + 26)
		local lhExtraLen = readUInt16(data, lhPos + 28)

		local dataPos = lhPos + 30 + lhNameLen + lhExtraLen
		local compressedData = data:sub(dataPos, dataPos + compressedSize - 1)

		-- decompress if needed
		local fileData
		if compressionMethod == COMPRESSION_DEFLATE then
			fileData = decompress(compressedData, uncompressedSize)
		elseif compressionMethod == COMPRESSION_STORED then
			fileData = compressedData
		else
			error("unsupported compression method: " .. compressionMethod)
		end

		-- store entry
		table.insert(archive.entries, {
				filename = filename,
				data = fileData,
				compressed_data = compressedData,
				compressed_size = compressedSize,
				uncompressed_size = uncompressedSize,
				compression_method = compressionMethod,
				crc32 = crc
			})

		pos = pos + 46 + fileNameLen + extraLen + commentLen
	end

	return archive
end

-- load archive from file
local function load(filename)
	local file = assert(io.open(filename, "rb"), "cannot open file: " .. filename)
	local data = file:read("*all")
	file:close()
	return read(data)
end

----------------------
-- metamethods
----------------------

function zip:__tostring()
	return string.format("<zip archive: %d files>", #self.entries)
end

function zip:__len()
	return #self.entries
end

function zip:__pairs()
	return pairs(self.entries)
end

----------------------
-- module export
----------------------

return {
	-- constructor
	new = new,

	-- i/o functions
	read = read,
	load = load,

	-- version info
	version = "1.0.0",
	zlibVersion = ZLIB_VERSION
}

--[[
usage example for zip.lua

-- creating a new archive
local zip = require("zip")
local archive = zip.new("optional comment")

-- adding files
archive:addFile("hello.txt", "hello world", true) -- compressed
archive:addFile("raw.bin", "\1\2\3\4", false) -- stored

-- saving to disk
archive:save("data.yip")

-- loading an existing archive
local loaded = zip.load("data.yip")

-- iterating through files
for _, entry in ipairs(loaded.entries) do
	print(entry.filename, #entry.data)
end

-- accessing file data directly
local file = loaded.entries[1]
print("first file:", file.filename)
print("contents:", file.data)

]]
