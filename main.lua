local zip = require("zip")


-- serialization example:
local serpent = require("serpent")


local resultLines = {} -- lines for on-screen display
local function log(msg) -- helper for printing
	print(msg)
	table.insert(resultLines, msg)
end

function love.load()


	-- test data

	-- example lua table
	local data = {1, 2, 3, a = {"empty"}, b = true, c = -3.14}
	local serStr = serpent.block (data)


	local filesToAdd = {
		{ name = "hello.txt", data = "Hello ZIP world!\nNewline"},
		{ name = "numbers.txt", data = "1234567890"},
		{ name = "lorem.txt", data = string.rep("lorem ipsum", 50)},
		{ name = "table.txt", data = serStr},
	}

	log("creating archive...")

	-- create new archive
	local archiveObj = zip.new("test archive comment")

	-- add test files
	for _, f in ipairs(filesToAdd) do
		log(" add: " .. f.name)
		archiveObj:addFile(f.name, f.data, true)
	end

	-- save archive
	local outName = "test.zip"
	archiveObj:save(outName)
	log("saved as: " .. outName)

	-- load and verify
	log("loading archive back...")
	local loaded = zip.load(outName)

	-- compare files
	log("verifying files...")
	for _, f in ipairs(filesToAdd) do
		local found = nil
		for _, e in ipairs(loaded.entries) do
			if e.filename == f.name then
				found = e
				break
			end
		end

		if not found then
			log(" [error] file missing: " .. f.name)
		else
			local ok = (found.data == f.data)
			if ok then
				log(" [ok] " .. f.name .. " matches")
			else
				log(" [fail] " .. f.name .. " differs")
			end
		end
	end

	log("done.")
end

function love.draw()
	love.graphics.setColor(1, 1, 1)
	local y = 20
	for _, line in ipairs(resultLines) do
		love.graphics.print(line, 20, y)
		y = y + 20
	end
end
