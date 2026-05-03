--!strict
-- EasyData
-- Single-module data system for Roblox.
-- Server owns the data, client receives a synced copy and can listen for changes.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local EasyData = {}

local REMOTE_NAME = "EasyData_Remote"
local DEFAULT_STORE_NAME = "EasyData"
local DEFAULT_KEY_PREFIX = "Player_"

export type Path = string | { string | number }

export type ServerOptions = {
	storeName: string?,
	template: { [any]: any },
	keyPrefix: string?,
	autoSaveInterval: number?,
	useAutoSave: boolean?,
}

-- Lightweight signal wrapper so this module stays self-contained.
local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({
		_event = Instance.new("BindableEvent"),
		_destroyed = false,
	}, Signal)
end

function Signal:Connect(handler: (...any) -> ())
	return self._event.Event:Connect(handler)
end

function Signal:Once(handler: (...any) -> ())
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		handler(...)
	end)
	return conn
end

function Signal:Fire(...)
	if self._destroyed then
		return
	end

	self._event:Fire(...)
end

function Signal:Wait()
	return self._event.Event:Wait()
end

function Signal:Destroy()
	if self._destroyed then
		return
	end

	self._destroyed = true
	self._event:Destroy()
end

-- Small table helpers.

local function deepClone<T>(value: T, seen: { [any]: any }?): T
	if type(value) ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] then
		return seen[value]
	end

	local copy = {}
	seen[value] = copy

	for k, v in pairs(value :: any) do
		copy[deepClone(k, seen)] = deepClone(v, seen)
	end

	return copy :: any
end

local function deepMerge(template: any, data: any): any
	if type(template) ~= "table" then
		return if data == nil then deepClone(template) else deepClone(data)
	end

	local result = deepClone(template)

	if type(data) ~= "table" then
		return result
	end

	for key, value in pairs(data) do
		if type(value) == "table" and type(result[key]) == "table" then
			result[key] = deepMerge(result[key], value)
		else
			result[key] = deepClone(value)
		end
	end

	return result
end

local function pathToString(path: Path): string
	if type(path) == "string" then
		return path
	end

	local pathString = ""
	for i, key in ipairs(path) do
		if i > 1 then
			pathString ..= "."
		end

		if type(key) == "number" then
			pathString ..= "#"
		end

		pathString ..= tostring(key)
	end

	return pathString
end

local function getPath(data: any, path: Path?): any
	if path == nil then
		return data
	end

	if type(path) == "string" then
		return data[path]
	end

	local current = data
	for _, key in ipairs(path) do
		current = current[key]
	end

	return current
end

local function setPath(data: any, path: Path, value: any): any
	if type(path) == "string" then
		local previous = data[path]
		data[path] = value
		return previous
	end

	local current = data
	for i = 1, #path - 1 do
		current = current[path[i]]
	end

	local lastKey = path[#path]
	local previous = current[lastKey]
	current[lastKey] = value
	return previous
end

-- Data wrapper that keeps local signals in one place.
local Data = {}
Data.__index = Data

type DataSignals = {
	changed: { [string]: any },
	indexChanged: { [string]: any },
	arrayInserted: { [string]: any },
	arrayRemoved: { [string]: any },
}

export type Data<T> = typeof(setmetatable(
	{} :: {
		_data: T,
		_signals: DataSignals,
	},
	Data
	))

function Data.new<T>(data: T): Data<T>
	local self = {
		_data = data,
		_signals = {
			changed = {},
			indexChanged = {},
			arrayInserted = {},
			arrayRemoved = {},
		},
	}

	setmetatable(self, Data)
	return self
end

function Data.get<T>(self: Data<T>, path: Path?): any
	return getPath(self._data, path)
end

function Data.set<T>(self: Data<T>, path: Path, value: any): any
	local previous = setPath(self._data, path, value)
	self:_firePathChangedSignals(path, previous)
	return previous
end

function Data.update<T>(self: Data<T>, path: Path, callback: (any) -> any): any
	local oldValue = self:get(path)
	local newValue = callback(oldValue)
	self:set(path, newValue)
	return newValue
end

function Data.arrayInsert<T>(self: Data<T>, path: Path, value: any, index: number?): ()
	local array = self:get(path)
	assert(type(array) == "table", "Data at path is not a table")

	if index then
		table.insert(array, index, value)
	else
		table.insert(array, value)
	end

	local pathString = self:_firePathChangedSignals(path)
	local signal = self._signals.arrayInserted[pathString]
	if signal then
		signal:Fire(index or #array, value)
	end
end

function Data.arrayRemove<T>(self: Data<T>, path: Path, index: number): any
	local array = self:get(path)
	assert(type(array) == "table", "Data at path is not a table")

	local value = table.remove(array, index)
	local pathString = self:_firePathChangedSignals(path)

	local signal = self._signals.arrayRemoved[pathString]
	if signal then
		signal:Fire(index, value)
	end

	return value
end

function Data.getChangedSignal<T>(self: Data<T>, path: Path)
	return self:_getSignal(path, "changed")
end

function Data.getIndexChangedSignal<T>(self: Data<T>, path: Path)
	return self:_getSignal(path, "indexChanged")
end

function Data.getArrayInsertedSignal<T>(self: Data<T>, path: Path)
	return self:_getSignal(path, "arrayInserted")
end

function Data.getArrayRemovedSignal<T>(self: Data<T>, path: Path)
	return self:_getSignal(path, "arrayRemoved")
end

function Data._getSignal<T>(self: Data<T>, path: Path, signalType: string)
	local pathString = pathToString(path)
	local signalBucket = self._signals[signalType]
	local signal = signalBucket[pathString]

	if not signal then
		signal = Signal.new()
		signalBucket[pathString] = signal
	end

	return signal
end

function Data._firePathChangedSignals<T>(self: Data<T>, path: Path, previous: any?): string
	if type(path) == "string" then
		self:_fireChangedSignal(path, self:get(path), previous)
		return path
	end

	local current = self._data
	local pathString = ""

	for i, key in ipairs(path) do
		current = current[key]

		if i > 1 then
			self:_fireIndexChangedSignal(pathString, key, current, previous)
			pathString ..= "."
		end

		if type(key) == "number" then
			pathString ..= "#"
		end

		pathString ..= tostring(key)
		self:_fireChangedSignal(pathString, current, previous)
	end

	return pathString
end

function Data._fireChangedSignal<T>(self: Data<T>, pathString: string, value: any, previous: any?)
	local signal = self._signals.changed[pathString]
	if signal then
		signal:Fire(value, previous)
	end
end

function Data._fireIndexChangedSignal<T>(self: Data<T>, pathString: string, index: string | number, value: any, previous: any?)
	local signal = self._signals.indexChanged[pathString]
	if signal then
		signal:Fire(index, value, previous)
	end
end

function Data.destroy<T>(self: Data<T>)
	for _, bucket in pairs(self._signals) do
		for _, signal in pairs(bucket) do
			signal:Destroy()
		end
	end

	self._signals = nil :: any
end

-- Shared action names for server/client replication.
local Actions = {
	init = "Init",
	set = "Set",
	arrayInsert = "ArrayInsert",
	arrayRemove = "ArrayRemove",
}

-- Server state.
local serverState = {
	initialized = false,
	options = nil :: ServerOptions?,
	store = nil :: GlobalDataStore?,
	remote = nil :: RemoteEvent?,
	sessions = {} :: {
		[Player]: {
			data: Data<any>,
			key: string,
			dirty: boolean,
		},
	},
	waitSignals = {} :: { [Player]: any },
	playerAddedConn = nil :: RBXScriptConnection?,
	playerRemovingConn = nil :: RBXScriptConnection?,
	closeBound = false,
}

-- Client state.
local clientState = {
	initialized = false,
	remote = nil :: RemoteEvent?,
	data = nil :: Data<any>?,
	readySignal = Signal.new(),
}

-- Server API.

EasyData.server = {}

function EasyData.server:Init(options: ServerOptions)
	assert(RunService:IsServer(), "EasyData.server can only be initialized on the server.")
	assert(not serverState.initialized, "EasyData has already been initialized.")
	assert(type(options) == "table", "EasyData.server:Init(options) expects a table.")
	assert(type(options.template) == "table", "EasyData.server:Init(options) requires a template table.")

	serverState.initialized = true
	serverState.options = options
	serverState.store = DataStoreService:GetDataStore(options.storeName or DEFAULT_STORE_NAME)

	local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = REMOTE_NAME
		remote.Parent = ReplicatedStorage
	end

	serverState.remote = remote :: RemoteEvent

	-- Existing players first, then new players.
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:_loadPlayer(player)
		end)
	end

	serverState.playerAddedConn = Players.PlayerAdded:Connect(function(player)
		self:_loadPlayer(player)
	end)

	serverState.playerRemovingConn = Players.PlayerRemoving:Connect(function(player)
		self:_unloadPlayer(player, true)
	end)

	if not serverState.closeBound then
		serverState.closeBound = true
		game:BindToClose(function()
			for player in pairs(serverState.sessions) do
				self:_unloadPlayer(player, true)
			end
		end)
	end
end

function EasyData.server:_keyFor(player: Player): string
	local options = serverState.options
	local prefix = options and options.keyPrefix or DEFAULT_KEY_PREFIX
	return prefix .. tostring(player.UserId)
end

function EasyData.server:_loadPlayer(player: Player)
	if not serverState.initialized then
		return
	end

	local options = serverState.options
	local store = serverState.store
	local remote = serverState.remote
	if not options or not store or not remote then
		return
	end

	local key = self:_keyFor(player)

	local success, storedData = pcall(function()
		return store:GetAsync(key)
	end)

	local mergedData
	if success and storedData ~= nil then
		mergedData = deepMerge(options.template, storedData)
	else
		mergedData = deepClone(options.template)
	end

	local data = Data.new(mergedData)
	serverState.sessions[player] = {
		data = data,
		key = key,
		dirty = false,
	}

	-- Wake anyone waiting for this player.
	local waitSignal = serverState.waitSignals[player]
	if waitSignal then
		waitSignal:Fire()
		waitSignal:Destroy()
		serverState.waitSignals[player] = nil
	end

	-- The player may have left while loading.
	if not player:IsDescendantOf(Players) then
		self:_unloadPlayer(player, false)
		return
	end

	remote:FireClient(player, Actions.init, deepClone(mergedData))
end

function EasyData.server:_savePlayer(player: Player)
	local session = serverState.sessions[player]
	local store = serverState.store
	if not session or not store then
		return
	end

	local success, err = pcall(function()
		store:SetAsync(session.key, deepClone(session.data._data))
	end)

	if not success then
		warn("[EasyData] Failed to save data for " .. player.Name .. ": " .. tostring(err))
		return
	end

	session.dirty = false
end

function EasyData.server:_unloadPlayer(player: Player, shouldSave: boolean)
	local session = serverState.sessions[player]
	if not session then
		return
	end

	if shouldSave then
		self:_savePlayer(player)
	end

	session.data:destroy()
	serverState.sessions[player] = nil

	local waitSignal = serverState.waitSignals[player]
	if waitSignal then
		waitSignal:Destroy()
		serverState.waitSignals[player] = nil
	end
end

function EasyData.server:WaitForData(player: Player): Data<any>
	local session = serverState.sessions[player]
	if session then
		return session.data
	end

	local waitSignal = serverState.waitSignals[player]
	if not waitSignal then
		waitSignal = Signal.new()
		serverState.waitSignals[player] = waitSignal
	end

	waitSignal:Wait()
	return serverState.sessions[player].data
end

function EasyData.server:HasData(player: Player): boolean
	return serverState.sessions[player] ~= nil
end

function EasyData.server:Get(player: Player, path: Path?): any
	return self:WaitForData(player):get(path)
end

function EasyData.server:Set(player: Player, path: Path, value: any, dontReplicate: boolean?)
	local session = serverState.sessions[player]
	assert(session, "No data session exists for " .. player.Name)

	session.data:set(path, value)
	session.dirty = true

	if not dontReplicate and serverState.remote then
		serverState.remote:FireClient(player, Actions.set, path, value)
	end
end

function EasyData.server:Update(player: Player, path: Path, callback: (any) -> any, dontReplicate: boolean?): any
	local session = serverState.sessions[player]
	assert(session, "No data session exists for " .. player.Name)

	local newValue = session.data:update(path, callback)
	session.dirty = true

	if not dontReplicate and serverState.remote then
		serverState.remote:FireClient(player, Actions.set, path, newValue)
	end

	return newValue
end

function EasyData.server:ArrayInsert(player: Player, path: Path, value: any, index: number?, dontReplicate: boolean?)
	local session = serverState.sessions[player]
	assert(session, "No data session exists for " .. player.Name)

	session.data:arrayInsert(path, value, index)
	session.dirty = true

	if not dontReplicate and serverState.remote then
		serverState.remote:FireClient(player, Actions.arrayInsert, path, value, index)
	end
end

function EasyData.server:ArrayRemove(player: Player, path: Path, index: number, dontReplicate: boolean?): any
	local session = serverState.sessions[player]
	assert(session, "No data session exists for " .. player.Name)

	local removed = session.data:arrayRemove(path, index)
	session.dirty = true

	if not dontReplicate and serverState.remote then
		serverState.remote:FireClient(player, Actions.arrayRemove, path, index)
	end

	return removed
end

function EasyData.server:GetChangedSignal(player: Player, path: Path)
	return self:WaitForData(player):getChangedSignal(path)
end

function EasyData.server:GetIndexChangedSignal(player: Player, path: Path)
	return self:WaitForData(player):getIndexChangedSignal(path)
end

function EasyData.server:GetArrayInsertedSignal(player: Player, path: Path)
	return self:WaitForData(player):getArrayInsertedSignal(path)
end

function EasyData.server:GetArrayRemovedSignal(player: Player, path: Path)
	return self:WaitForData(player):getArrayRemovedSignal(path)
end

function EasyData.server:Save(player: Player)
	self:_savePlayer(player)
end

function EasyData.server:SaveAll()
	for player in pairs(serverState.sessions) do
		self:_savePlayer(player)
	end
end

-- Client API.

EasyData.client = {}

function EasyData.client:Init()
	if clientState.initialized then
		return
	end

	clientState.initialized = true

	local remote = ReplicatedStorage:WaitForChild(REMOTE_NAME)
	clientState.remote = remote :: RemoteEvent

	clientState.remote.OnClientEvent:Connect(function(action: string, ...)
		if action == Actions.init then
			local initialData = ...
			clientState.data = Data.new(initialData)
			clientState.readySignal:Fire()
			return
		end

		local data = clientState.data
		if not data then
			return
		end

		if action == Actions.set then
			local path, value = ...
			data:set(path, value)
		elseif action == Actions.arrayInsert then
			local path, value, index = ...
			data:arrayInsert(path, value, index)
		elseif action == Actions.arrayRemove then
			local path, index = ...
			data:arrayRemove(path, index)
		end
	end)
end

function EasyData.client:WaitForData(): Data<any>
	if not clientState.initialized then
		self:Init()
	end

	if clientState.data then
		return clientState.data
	end

	clientState.readySignal:Wait()
	return clientState.data
end

function EasyData.client:IsReady(): boolean
	return clientState.data ~= nil
end

function EasyData.client:Get(path: Path?): any
	return self:WaitForData():get(path)
end

function EasyData.client:Set(path: Path, value: any)
	self:WaitForData():set(path, value)
end

function EasyData.client:Update(path: Path, callback: (any) -> any): any
	return self:WaitForData():update(path, callback)
end

function EasyData.client:ArrayInsert(path: Path, value: any, index: number?)
	self:WaitForData():arrayInsert(path, value, index)
end

function EasyData.client:ArrayRemove(path: Path, index: number): any
	return self:WaitForData():arrayRemove(path, index)
end

function EasyData.client:GetChangedSignal(path: Path)
	return self:WaitForData():getChangedSignal(path)
end

function EasyData.client:GetIndexChangedSignal(path: Path)
	return self:WaitForData():getIndexChangedSignal(path)
end

function EasyData.client:GetArrayInsertedSignal(path: Path)
	return self:WaitForData():getArrayInsertedSignal(path)
end

function EasyData.client:GetArrayRemovedSignal(path: Path)
	return self:WaitForData():getArrayRemovedSignal(path)
end

return EasyData
