--[[
Functions that facilitate loading, parsing and storing of config files.
]]

_libs = _libs or {}
_libs.config = true
_libs.logger = _libs.logger or require 'logger'
_libs.tablehelper = _libs.tablehelper or require 'tablehelper'
_libs.stringhelper = _libs.stringhelper or require 'stringhelper'
local json = require 'json'
_libs.json = _libs.json or (json ~= nil)
local xml = require 'xml'
_libs.xml = _libs.xml or (xml ~= nil)
local files = require 'filehelper'
_libs.filehelper = _libs.filehelper or (files ~= nil)

local config = T(config) or T{}
local file = files.new()
local original = T{['global'] = T{}}
local chars = T{}
local comments = T{}

--[[
	Local functions
]]

local parse
local settings_table
local settings_xml
local nest_xml
local table_diff

-- Loads a specified file, or alternatively a file 'settings.json' or 'settings.xml' in the current addon folder.
-- Writes all configs to _config.
function config.load(filename, confdict, overwrite)
	if type(filename) == 'table' then
		confdict, filename, overwrite = filename, nil, confdict
	elseif type(filename) == 'boolean' then
		filename, overwrite = nil, filename
	elseif type(confdict) == 'boolean' then
		confdict, overwrite = nil, confdict
	end
	confdict = T(confdict) or T{}
	overwrite = overwrite or false
	
	local confdict_mt = getmetatable(confdict)
	confdict = setmetatable(confdict, {__index = function(t, x) if x == 'save' then return config['save'] else return confdict_mt.__index[x] end end})
	
	-- Sets paths depending on whether it's a script or addon loading this file.
	local filepath = filename or files.check('data/settings.xml')
	if filepath == nil then
		file:set('data/settings.xml', true)
		original['global'] = confdict:copy()
		confdict:save()
		return confdict
	end
	file:set(filepath)

	-- Load addon/script config file (Windower/addon/<addonname>/config.json for addons and Windower/scripts/<name>-config.json).
	local err
	confdict, err = parse(file, confdict, overwrite)

	if err ~= nil then
		error(err)
	end
	
	return confdict
end

-- Resolves to the correct parser and calls the respective subroutine, returns the parsed settings table.
function parse(file, confdict, update)
	local parsed = T{}
	local err
	if file.path:endswith('.json') then
		parsed = json.read(file)
	elseif file.path:endswith('.xml') then
		parsed, err = xml.read(file)
		if parsed == nil then
			if err ~= nil then
				error(err)
			else
				error('XML error: Unkown error.')
			end
			return T{}
		end
		parsed = settings_table(parsed, confdict)
	end
	
	-- Determine all characters found in the settings file.
	chars = parsed:keyset():filter(-functools.equals('global'))
	original = T{}
	
	if update or confdict:isempty() then
		for _, char in ipairs(T{'global'}+chars) do
			original[char] = confdict:copy():update(parsed[char], true)
		end
		return confdict:update(parsed['global']:update(parsed[get_player()['name']:lower()], true), true)
	end
	
	-- Update the global settings with the per-player defined settings, if they exist. Save the parsed value for later comparison.
	for _, char in ipairs(T{'global'}+chars) do
		original[char] = confdict:copy():merge(parsed[char])
	end
	
	return confdict:merge(parsed['global']:update(parsed[get_player()['name']:lower()], true))
end

-- Parses a settings struct from a DOM tree.
function settings_table(node, confdict, key)
	confdict = confdict or T{}
	key = key or 'settings'
	
	local t = T{}
	if node.type ~= 'tag' then
		return t
	end
	
	if not node.children:all(function (n) return n.type == 'tag' or n.type == 'comment' end) and not (#node.children == 1 and node.children[1].type == 'text') then
		error('Malformatted settings file.')
		return t
	end
	
	if node.children:length() == 1 and node.children[1].type == 'text' then
		local val = node.children[1].value
		if val:lower() == 'false' then
			return false
		elseif val:lower() == 'true' then
			return true
		end
		
		local num = tonumber(val)
		if num ~= nil then
			return num
		end
		
		if confdict:containskey(node.name) and type(confdict[node.name]) == 'table' then
			return val:psplit('%s*,%s*')
		end
		
		return val
	end
	
	for _, child in ipairs(node.children) do
		if child.type == 'comment' then
			comments[key] = child.value
		elseif child.type == 'tag' then
			key = child.name:lower()
			local childdict
			if confdict:containskey(key) then
				childdict = confdict:copy()
			else
				childdict = confdict
			end
			t[child.name:lower()] = settings_table(child, childdict, key)
		end
	end
	
	return t
end

-- Writes the passed config table to the spcified file name.
-- char defaults to get_player()['name']. Set to "all" to apply to all characters.
function config.save(t, char)
	char = (char or get_player()['name']):lower()
	if char == 'all' then
		char = 'global'
	elseif not chars:contains(char) then
		chars:append(char)
		original[char] = T{}
	end
	
	original[char]:update(t)
	
	if char == 'global' then
		original = original:filterkey('global')
	else
		original[char] = table_diff(original['global'], original[char]) or T{}
		
		if original[char]:isempty() then
			original[char] = nil
			chars:delete(char)
		end
	end
	
	file:write(settings_xml(original))
end

-- Returns the table containing only elements from t_new that are different from t and not nil.
function table_diff(t, t_new)
	local res = T{}
	local cmp
	
	for key, val in pairs(t_new) do
		cmp = t[key]
		if cmp ~= nil then
			if type(cmp) ~= type(val) then
				warning('Mismatched setting types for key \''..key..'\':', type(cmp), type(val))
			else
				if type(val) == 'table' then
					val = T(val)
					cmp = T(cmp)
					if val:isarray() and cmp:isarray() then
						if not val:equals(cmp) then
							res[key] = val
						end
					else
						res[key] = table_diff(cmp, val)
					end
				elseif cmp ~= val then
					res[key] = val
				end
			end
		end
	end
	
	if res:isempty() then
		return nil
	end
	
	return res
end

-- Converts a settings table to a XML representation.
function settings_xml(settings)
	local str = '<?xml version="1.1" ?>\n'
	str = str..'<settings>\n'
	
	chars = settings:keyset():filter(-functools.equals('global')):sort()
	for _, char in ipairs(T{'global'}+chars) do
		if char == 'global' and comments['settings'] ~= nil then
			str = str..'\t<!--\n'
			str = str..'\t\t'..comments['settings']..'\n'
			str = str..'\t-->\n'
		end
		str = str..'\t<'..char..'>\n'
		str = str..nest_xml(settings[char], 2)
		str = str..'\t</'..char..'>\n'
	end
	
	str = str..'</settings>\n'
	return str
end

-- Converts a table to XML without headers using appropriate indentation and comment spacing. Used in settings_xml.
function nest_xml(t, indentlevel)
	indentlevel = indentlevel or 0
	local indent = ('\t'):rep(indentlevel)
	
	local inlines = T{}
	local fragments = T{}
	local maxlength = 0		-- For proper comment indenting
	keys = t:keyset():sort()
	local val
	for _, key in ipairs(keys) do
		val = t[key]
		if type(val) == 'table' and not T(val):isarray() then
			fragments:append(indent..'<'..key..'>\n')
			if comments[key] ~= nil then
				local c = ('<!-- '..comments[key]:trim()..' -->'):split('\n')
				local pre = ''
				for _, cstr in pairs(c) do
					fragments:append(indent..pre..cstr:trim()..'\n')
					pre = '\t '
				end
			end
			fragments:append(nest_xml(val, indentlevel + 1))
			fragments:append(indent..'</'..key..'>\n')
		else
			if type(val) == 'table' then
				val = T(val):sort():format('csv')
			end
			val = tostring(val)
			if val == '' then
				fragments:append(indent..'<'..key..' />')
			else
				fragments:append(indent..'<'..key..'>'..val..'</'..key..'>')
			end
			local length = fragments:last():length() - indent:length()
			if length > maxlength then
				maxlength = length
			end
			inlines[fragments:length()] = key
		end
	end
	
	for frag_key, key in pairs(inlines) do
		if comments[key] ~= nil then
			fragments[frag_key] = fragments[frag_key]..(' '):rep(maxlength - fragments[frag_key]:trim():length() + 1)..'<!--'..comments[key]..'-->'
		end
		
		fragments[frag_key] = fragments[frag_key]..'\n'
	end
	
	return fragments:concat()
end

-- Resets all data. Always use when loading within a library.
function config.reset()
	config = T(config) or T{}
	file = files.new()
	original = T{['global'] = T{}}
	chars = T{}
	comments = T{}
end

return config
