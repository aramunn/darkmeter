-------------------------------------------------------------
-- Fight class
-------------------------------------------------------------
-- each instance is an ingame fight (in and out of combat)
-- contains references to players, their skills and dmg...
-------------------------------------------------------------

require "Window"

local Fight = {}

-- external classes
local Unit = Apollo.GetPackage("DarkMeter:Unit").tPackage
local Skill = Apollo.GetPackage("DarkMeter:Skill").tPackage
local DMUtils = Apollo.GetPackage("DarkMeter:Utils").tPackage
local DarkMeter
local fightsTableIndex = 0
local next = next

function Fight:new()
  if DarkMeter == nil then
    DarkMeter = Apollo.GetAddon("DarkMeter")
  end
  fightsTableIndex = fightsTableIndex + 1

  local fight = {}
  fight.groupMembers = {}
  fight.enemies = {}
  fight.startTime = GameLib.GetGameTime()
  fight.forcedName = nil -- this is used to force a fight name like "Current fight" or "Overall data"
  fight.totalDuration = 0
  fight.pvpMatch = false
  fight.id = fightsTableIndex
  -- reference for total danageDone, healing...
  fight.damageDoneTotal = 0
  fight.healingDoneTotal = 0
  fight.overhealDoneTotal = 0
  fight.interruptsTotal = 0
  fight.absorbsDoneTotal = 0
  fight.absorbsTakenTotal = 0
  fight.damageTakenTotal = 0
  fight.deathsTotal = 0

  self.__index = self
  setmetatable(fight, self)

  DarkMeter.fights[fight.id] = fight
  return fight
end

-- adds an unit to the current fight
-- groupMember is a boolean, if true the unit is added to the friendly units, if false is added to the enemies
-- return true if unit is added
-- return false if unit exists
function Fight:addUnit(wsUnit, groupMember)
  local unitId = wsUnit:GetId()
  local unitName = wsUnit:GetName()
  local unitTable = groupMember and "groupMembers" or "enemies"

  if self[unitTable][unitId] ~= nil then
    return false
  else
    -- if the unit is not a pet and a unit with this name exists among the actual group members, it might be a player that crashed with the same name, but after relog now has a different id
    -- this also is used when changing zones...
    -- tldr... merge groupMembers that are not pets with the same name
    if groupMember and not wsUnit:GetUnitOwner() then
      for id, unit in next, self.groupMembers do
        if unit.name == unitName then
          -- -- create a new unit that is the clone of the previous unit with the same name
          local newUnit = DMUtils.cloneTable(unit)
          newUnit.id = unitId
          -- delete old unit and add new one to the groupMembers
          self.groupMembers[id] = nil
          self.groupMembers[newUnit.id] = newUnit
          break
        end
      end
    end

    -- adds a new unit if no old unit has been merged
    if self[unitTable][unitId] == nil then
      self[unitTable][unitId] = Unit:new(wsUnit)
      self[unitTable][unitId].fightId = self.id
      self[unitTable][unitId].enemy = not groupMember
    end
    if self[unitTable][unitId].pet then
      self:addUnit(self[unitTable][unitId].owner, groupMember)
    end
    if groupMember then
      self[unitTable][unitId]:startFight() -- used to calculate dps
    end
    return true
  end
end

-- duration of the fight
function Fight:duration()
  if not self.endTime then
    return math.floor(GameLib.GetGameTime() - self.startTime + self.totalDuration)
  else
    return math.floor(self.totalDuration)
  end
end

-- stops fight (combat end)
function Fight:stop()
  if not self.endTime then
    self.endTime = GameLib.GetGameTime()
    self.totalDuration = self.totalDuration + (self.endTime - self.startTime)

    for _, unit in next, self.groupMembers do
      unit:stopFight()
    end
  end
end

-- continue a fight, used to keep adding time to the overall fight between combats
function Fight:continue()
  if self.endTime then
    self.startTime = GameLib.GetGameTime()
    self.endTime = nil
    for _, unit in next, self.groupMembers do
      unit:startFight()
    end
  end
end

function Fight:paused()
  return self.startTime and self.endTime
end

local stats = {"damageDone", "healingDone", "overhealDone", "interrupts", "absorbsDone", "absorbsTaken", "damageTaken", "deaths"}

for i = 1, #stats do
  Fight[stats[i]] = function(self)
    return self[stats[i] .. "Total"]
  end
end

function Fight:rawhealDone()
  return self:healingDone() + self:overhealDone()
end

function Fight:absorbHealingDone()
  SendVarToRover("Absorb", self:absorbsDone())
  SendVarToRover("Healing", self:healingDone())
  return self:healingDone() + self:absorbsDone()
end

function Fight:dps()
  local total = 0
  local duration = 0.1
  if self:duration() > 0 then
    duration = self:duration()
  end
  for _, unit in next, self.groupMembers do
    total = total + unit:damageDone()
  end
  return total / duration
end

function Fight:hps()
  local total = 0
  local duration = 0.1
  if self:duration() > 0 then
    duration = self:duration()
  end
  for _, unit in next, self.groupMembers do
    total = total + unit:healingDone()
  end
  return total / duration
end

-- return an ordered list of all party members ordered by the diven stats
function Fight:orderMembersBy(stat)
  if Unit[stat] == nil then
    error("Cannot order fight members by " .. stat .. " Unit class doesn't have such method")
  end

  local function sortNormal(a, b)
    return a[stat](a) > b[stat](b)
  end

  local function sortPleb(a, b)
    return a[stat](a) < b[stat](b)
  end

  local tmp = {}
  for _, unit in next, self.groupMembers do
    tmp[#tmp + 1] = unit
    if not DarkMeter.settings.mergePets then
      for _, pet in next, unit.pets do
        tmp[#tmp + 1] = pet
      end
    end
  end

  if #tmp > 1 then
    if not DarkMeter.settings.sortMode then
      table.sort(tmp, sortNormal)
    else
      table.sort(tmp, sortPleb)
    end
  end
  return tmp
end

-- returns the name of the most significative enemies
function Fight:name()
  if self.forcedName then
    return self.forcedName
  end
  local topUnit = nil
  for _, unit in next, self.enemies do
    topUnit = topUnit or unit
    -- TODO
    -- I've implemented this part because in some fights vs some real mobs, I've found my own name as the fight's name
    -- maybe is something generated from some strange buff or an attack reflected pheraps?
    if unit.rank > topUnit.rank and not self.groupMembers[unit.id] then
      topUnit = unit
    end
  end
  return topUnit and topUnit.name or "No enemies"
end

Apollo.RegisterPackage(Fight, "DarkMeter:Fight", 1, {"DarkMeter:Skill", "DarkMeter:Unit"})
