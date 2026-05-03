# EasyData

EasyData is a simple data system for Roblox that keeps things clean and predictable.

---

## ✨ Features

* Server-controlled data (no trusting the client)
* Automatic syncing to the client
* Change signals (react to updates instantly)
* Works with nested data using paths
* Handles DataStore loading + saving
* Single module, no dependencies

---

## ⚙️ Basic Setup (Server)

```lua
local EasyData = require(ReplicatedStorage:WaitForChild("EasyData"))

EasyData.server:Init({
    template = {
        Coins = 0,
        Inventory = {},
        Stats = {
            Level = 1,
            XP = 0,
        },
    }
})
```

---

## 📥 Getting Data

```lua
local data = EasyData.server:WaitForData(player)

print(data:get("Coins"))
```

---

## ✏️ Updating Data

```lua
EasyData.server:Set(player, "Coins", 100)

EasyData.server:Update(player, "Coins", function(old)
    return old + 10
end)
```

---

## 📦 Arrays

```lua
EasyData.server:ArrayInsert(player, "Inventory", "Sword")
EasyData.server:ArrayRemove(player, "Inventory", 1)
```

---

## 📡 Listening to Changes

```lua
EasyData.server:GetChangedSignal(player, "Coins"):Connect(function(new, old)
    print("Coins changed:", old, "->", new)
end)
```

---

## 💻 Client

```lua
EasyData.client:Init()

local data = EasyData.client:WaitForData()
print(data:get("Coins"))
```

```lua
EasyData.client:GetChangedSignal("Coins"):Connect(function(new)
    print("Coins updated:", new)
end)
```
