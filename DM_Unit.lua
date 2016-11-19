require "Window"
-------------------------------------------------------------
-- Unit class
-------------------------------------------------------------
-- each instance is an ingame unit (player or mob)
-- depends on the Skill class
-------------------------------------------------------------

local Unit = {}
local next = next

-- external classes
local Skill = Apollo.GetPackage("DarkMeter:Skill").tPackage
local DarkMeter
local DMUtils = Apollo.GetPackage("DarkMeter:Utils").tPackage
local unitTableIndex = 0

-- wsUnit is a wildstar Unit, check the api for more infos on the Unit API Type
function Unit:new(wsUnit)
  if DarkMeter == nil then
    DarkMeter = Apollo.GetAddon("DarkMeter")
  end
  unitTableIndex = unitTableIndex + 1

  local unit = {}
  unit.id = wsUnit:GetId()
  unit.level = wsUnit:GetLevel()
  unit.rank = wsUnit:GetRank()
  unit.classId = wsUnit:GetClassId()
  unit.name = wsUnit:GetName()
  unit.fightId = nil -- key to retrieve the fight that this unit belongs to in the table DarkMeter.fights
  unit.inCombat = wsUnit:IsInCombat()
  unit.skills = {} -- all skill casted by that unit, key is the skill name, and the value is a Skill instance
  unit.damagingSkillsTaken = {} -- all skills casted from enemies to the unit (storead as: {enemyName = {skillname = Skill, skillname2 = skill2}})
  unit.absorbsSkillsTaken = {} -- all skills casted from enemies to the unit (storead as: {enemyName = {skillname = Skill, skillname2 = skill2}})
  unit.deathCount = 0
  unit.deathsRecap = {} -- array of tables, each table is like {timestamp = {GameLib.GetLocalTime()}, skills = array with the last 10 skills taken}
  unit.totalFightTime = 0
  unit.lastActionTimestamp = nil -- timestamp of the last action, used to calc dps
  unit.pets = {} -- table: key = pet name, value = Unit instance
  unit.lastTenDamagingSkillsTaken = {} -- array of skills stored as formattedSkill NOT as a skill instance! used for death recap
  unit.enemy = false
  unit.customId = unitTableIndex -- unfortunately, in this case the id key was already in use and have to do this to reference the global units table

  -- if the unit has an owner is a pet
  if wsUnit:GetUnitOwner() then
    unit.owner = wsUnit:GetUnitOwner()
    unit.ownerId = wsUnit:GetUnitOwner():GetId()
    unit.pet = true
  else
    unit.pet = false
  end

  self.__index = self
  setmetatable(unit, self)
  DarkMeter.units[unit.customId] = unit
  return unit
end

-- timer funtions used to calculate stats/second
function Unit:startFight()
  if self.startTime == nil then
    self.startTime = GameLib.GetGameTime()
    self.stopTime = nil
    self.lastActionTimestamp = nil
    for _, unit in next, self.pets do
      unit:startFight()
    end
  end
end

function Unit:stopFight()
  if self.stopTime == nil and self.startTime ~= nil then
    self.stopTime = GameLib.GetGameTime()
    self.totalFightTime = self.totalFightTime + ( (self.lastActionTimestamp or self.stopTime) - self.startTime)
    for _, unit in next, self.pets do
      unit:stopFight()
    end
    self.startTime = nil
    self.lastActionTimestamp = nil
  end
end

function Unit:fightDuration()
  if self.startTime or self.totalFightTime > 0 then
    if self.stopTime then
      return math.floor(self.totalFightTime)
    elseif self.startTime then
      return math.floor(self.totalFightTime + ( (self.lastActionTimestamp or GameLib.GetGameTime()) - self.startTime) )
    else
      return 0
    end
  else
    return 0
  end
end

-- adds a pet to this unit
function Unit:addPet(wsUnit)
  local name = wsUnit:GetName()
  if self.pets[name] == nil then
    self.pets[name] = Unit:new(wsUnit)
    self.pets[name]:startFight()
    return true
  end
  return false
end

-- adds a skill to the caster unit
function Unit:addSkill(skill)
  -- special condition, ignore falling damage, as it gets added also as skilltaken
  if not skill.selfDamage then
    -- expire cached values
    self:expireCache()

    if not self.skills[skill.name] then
      local tmpSkill = Skill:new()
      tmpSkill.fightId = self.fightId
      tmpSkill.unitId = self.customId
      self.skills[skill.name] = tmpSkill
    end
    self.skills[skill.name]:add(skill)
    self.lastActionTimestamp = GameLib.GetGameTime()
  end
end

-- adds a skill taken from an enemy
function Unit:addSkillTaken(skill)
  -- expire cached values
  self:expireCacheSkillsTaken()

  -- process damage taken
  if skill.typology == "damage" then
    local name = skill.fallingDamage == true and "Gravity" or skill.casterName

    if not self.damagingSkillsTaken[name] then
      self.damagingSkillsTaken[name] = {}
    end
    if not self.damagingSkillsTaken[name][skill.name] then
      local tmpSkill = Skill:new()
      tmpSkill.fightId = self.fightId
      tmpSkill.unitId = self.customId
      tmpSkill.skillTaken = true
      self.damagingSkillsTaken[name][skill.name] = tmpSkill
    end
    self.damagingSkillsTaken[name][skill.name]:add(skill)
    -- add to the last 10 damage taken
    table.insert(self.lastTenDamagingSkillsTaken, 1, skill)
    self.lastTenDamagingSkillsTaken[11] = nil

    -- if this unit is killed while taking this damage
    if skill.targetkilled == true then
      -- increment death counter
      self.deathCount = self.deathCount + 1
      -- create death recap with timestamp and last 10 damaging skills taken
      local deathRecap = {
        timestamp = GameLib.GetLocalTime(),
        killerName = skill.casterName
      }
      deathRecap.skills = DMUtils.cloneTable(self.lastTenDamagingSkillsTaken)
      table.insert(self.deathsRecap, 1, deathRecap)
      self.lastTenDamagingSkillsTaken = {}
    end
  elseif skill.typology == "healing" then
    -- TODO process healing taken
    -- this might be a future trackable stat, I don't think is very useful for now
  end
  self.lastActionTimestamp = GameLib.GetGameTime()
end

------------------------------------------
-- skills processing functons
------------------------------------------
-- those functions sum all the player's skills and return a number
-- representing the amount of this unit's stat (like damageDone for example)

-- returns damage taken
function Unit:damageTaken()
  -- if tere's no cached value, calculate it and set cache
  if self.damageTakenCached == nil then
    local total = 0
    for _, skills in next, self.damagingSkillsTaken do
      for _, skill in next, skills do
        total = total + skill.damageDone
      end
    end
    self.damageTakenCached = total
  end
  -- return cached value
  return self.damageTakenCached
end

-- returns damage taken
function Unit:absorbsTaken()
  -- if tere's no cached value, calculate it and set cache
  if self.absorbsTakenCached == nil then
    local total = 0
    for _, skills in next, self.absorbsSkillsTaken do
      for _, skill in next, skills do
        total = total + skill.absorbsDone
      end
    end
    self.absorbsTakenCached = total
  end
  -- return cached value
  return self.absorbsTakenCached
end

local stats = {"damageDone", "healingDone", "overhealDone", "interrupts", "absorbsDone", "rawhealDone", "absorbHealingDone"}

-- define functions to return the stats in this array, since they share the same logic
for i = 1, #stats do
  Unit[stats[i]] = function(self)
    -- if there's no cached value, calculate it and cache it
    if self[stats[i] .. "Cached"] == nil then
      local total = 0
      for _, skill in next, self.skills do
        total = total + skill:dataFor(stats[i])
      end
      if DarkMeter.settings.mergePets then
        for _, pet in next, self.pets do
          total = total + pet[stats[i]](pet)
        end
      end
      self[stats[i] .. "Cached"] = total
    end
    -- return cached value
    return self[stats[i] .. "Cached"]
  end
end

function Unit:deaths()
  return self.deathCount
end

function Unit:dps()
  if self:fightDuration() > 0 then
    return math.floor( self:damageDone() / self:fightDuration() )
  else
    return 0
  end
end

function Unit:hps()
  if self:fightDuration() > 0 then
    return math.floor( self:healingDone() / self:fightDuration() )
  else
    return 0
  end
end

------------------------------------------
-- skills order function
------------------------------------------
-- those functions will sort all unit's skills based on their contribution to a particolar stat score and return them as an array
-- all the skills that give 0 contribution to that stat are excluded from the resulting array

for i = 1, #stats do
  Unit[stats[i] .. "Skills"] = function(unit)
    local tmp = {}

    local function sortFunct(a, b)
      return a:dataFor(stats[i]) > b:dataFor(stats[i])
    end

    local skills = DarkMeter.settings.mergeDots and unit:mergedSkills() or unit.skills

    for _, skill in next, skills do
      local amount = skill:dataFor(stats[i])
      if amount > 0 then
        tmp[#tmp + 1] = skill
      end
    end

    -- add pet's skills if pets are merged with the owner
    if DarkMeter.settings.mergePets then
      for _, pet in next, unit.pets do
        for _, skill in next, pet.skills do
          local amount = skill:dataFor(stats[i])
          if amount > 0 then
            tmp[#tmp + 1] = skill
          end
        end
      end
    end

    if #tmp > 1 then
      table.sort(tmp, sortFunct)
    end
    return tmp
  end
end

-- returns all the skills taken as an array of skills
function Unit:damageTakenSkills()
  local tmp = {}
  local function sortFunct(a, b)
    return a.damageDone > b.damageDone
  end

  for _, skills in next, self.damagingSkillsTaken do
    for _, skill in next, skills do
      if skill.damageDone > 0 then
        tmp[#tmp + 1] = skill
      end
    end
  end

  if #tmp > 1 then
    table.sort(tmp, sortFunct)
  end
  return tmp
end

-- returns a table {{name = strEnemyName, damage = nDamageDone}, ...}
function Unit:damageTakenOrderedByEnemies()
  local tmp = {}
  local function sortFunct(a, b)
    return a.damage > b.damage
  end

  for enemy, skills in next, self.damagingSkillsTaken do
    local skilltotal = 0
    for _, skill in next, skills do
      skilltotal = skilltotal + skill.damageDone
    end
    local tmpDmg = {}
    tmpDmg.name = enemy
    tmpDmg.damage = skilltotal
    tmp[#tmp + 1] = tmpDmg
  end

  if #tmp > 1 then
    table.sort(tmp, sortFunct)
  end
  return tmp
end

------------------------------------------
-- end skill order
------------------------------------------

function Unit:mergedSkills()
  local tmpSkills = {}
  for name, skill in next, self.skills do
    -- if the skill is the dot
    if skill.originalName ~= nil then
      if tmpSkills[skill.originalName] == nil then
        tmpSkills[skill.originalName] = DMUtils.cloneTable(skill)
      else
        tmpSkills[skill.originalName]:merge(skill)
      end
    else
      -- if the skill is the base spell
      if tmpSkills[name] == nil then
        tmpSkills[name] = DMUtils.cloneTable(skill)
      else
        local clone = DMUtils.cloneTable(skill)
        clone:merge(tmpSkills[name])
        tmpSkills[name] = clone
      end
    end
  end

  return tmpSkills
end

-- returns integer percentage of crit, multihit, deflects...
function Unit:statsPercentages(sStat)
  local total = 0 -- total will hold the total number of skills thrown, crical and not + multihits + multicrits + deflects
  local multi = 0
  local multicrit = 0
  local crit = 0
  local deflects = 0

  local key
  if sStat == "damageDone" then
    key = "damage"
  elseif sStat == "healingDone" or sStat == "overhealDone" or sStat == "rawhealDone" or sStat == "absorbHealingDone" then
    key = "heals"
  elseif sStat == "damageTaken" then
    key = "damagingSkillsTaken"
  elseif sStat == "absorbsTaken" or sStat == "absorbsDone" then
    key = "absorbs"

  end

  if key then
    if key == "damagingSkillsTaken" then
      for _, skills in next, self.damagingSkillsTaken do
        for _, skill in next, skills do
          total = total + skill.damage.total
          multi = multi + #skill.damage.multihits
          multicrit = multicrit + #skill.damage.multicrits
          crit = crit + #skill.damage.crits

          if key == "damage" then
            deflects = deflects + skill.damage.deflects
          end
        end
      end
    else
      for _, skill in next, self.skills do
        total = total + skill[key].total
        multi = multi + #skill[key].multihits
        multicrit = multicrit + #skill[key].multicrits
        crit = crit + #skill[key].crits

        if key == "damage" then
          deflects = deflects + skill.damage.deflects
        end
      end
    end

    local percentages = {}
    if multi > 0 then
      percentages.multihits = multi / total *100
    else
      percentages.multihits = 0
    end
    if multicrit > 0 then
      percentages.multicrits = multicrit / total * 100
    else
      percentages.multicrits = 0
    end
    if crit > 0 then
      percentages.crits = crit / total * 100
    else
      percentages.crits = 0
    end
    if key == "damage" then
      if deflects > 0 then
        percentages.deflects = deflects / (total + multicrit + multi) * 100
      else
        percentages.deflects = 0
      end
    end
    percentages.attacks = total
    if total > 0 and tonumber(self:fightDuration()) > 0 then
      local swings = DMUtils.roundToNthDecimal((total / self:fightDuration()), 2)
      percentages.swings = swings
    else
      percentages.swings = 0
    end

    return percentages
  end
end

-- sets all the cached values to nil
-- this function is called whenever a skill is added to the unit
function Unit:expireCache()
  self.damageDoneCached = nil
  self.healingDoneCached = nil
  self.overhealDoneCached = nil
  self.interruptsCached = nil
  self.rawhealDoneCached = nil
  self.absorbsDoneCached = nil
  self.absorbHealingDoneCached = nil
end

-- this function is called whenever a skilltaken is added to the unit
function Unit:expireCacheSkillsTaken()
  self.damageTakenCached = nil
  self.absorbsTakenCached = nil
end

Apollo.RegisterPackage(Unit, "DarkMeter:Unit", 1, {"DarkMeter:Skill"})
