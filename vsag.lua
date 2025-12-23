-- ============================================================
-- EdgeTX Lua: BatP (%) + Sag (compensated per-cell V) + Cell (raw per-cell V)
-- Additional sensor:
--   Ratio : applied compensation ratio (0..100%)
--
-- File: vsag.lua
-- License: MIT (see LICENSE in repository root)
-- Credits: Created by Itay Sharoni with use of AI.
--
-- SC4 FIX:
-- 1) capCell (rest reference cap) is ONLY updated after confirmed recovery PLATEAU.
--    This prevents capCell from collapsing during brief throttle dips and removes
--    the "Sag falls back to Cell at full throttle" failure mode.
-- 2) Add decayApplyFactor to globally slow applied OCV decay while still learning DCR.
--
-- SD persistence (SAFE):
--   /SCRIPTS/DATA/SagComp_<ModelName>.dat
--   Stores: RECOV, SAG, DOWN, DCR, CHEM
-- ============================================================

-- ===== User sensor names =====
local myBatSensorName  = "RxBt"
local myBatPercentName = "BatP"
local mySagCellName    = "Sag"    -- compensated per-cell
local myRawCellName    = "Cell"   -- raw per-cell
local myThrSourceName  = "ch3"    -- throttle INPUT
local myRatioName      = "Ratio"  -- 0..100 (%)

-- ===== Chemistry handling (BatP %) =====
-- 0 = Auto detect (recommended)
-- 1 = Force LiPo  (4.20V = 100%)
-- 2 = Force LiHV  (4.35V = 100%)
local chemistryMode         = 0
local lihvDetectV           = 4.23   -- latch LiHV if seen >= this V/cell at low throttle
local lihvDetectSamplesNeed = 3      -- consecutive samples required to latch

-- ===== Timing (centiseconds; 100 = 1s) =====
local warmupDelayCS    = 200
local fallbackUpdateCS = 50
local minUpdateCS      = 30
local maxUpdateCS      = 150
local adaptiveRate     = true

-- ===== Throttle thresholds (0..1) =====
local thrRestPct       = 0.10     -- <=10%: rest/recovery zone
local thrNoCompPct     = 0.10     -- <=10%: NO compensation
local thrRampEndPct    = 0.30     -- 10%..30%: ramp compensation in
local thrCapturePct    = 0.18     -- capture minima and learn sag above this

-- ===== Recovery handling =====
local recoverDelayCSDefault = 200  -- default 2s if no learned value yet
local lowPeakEmaAlpha       = 0.60

-- ===== Recovery learning / plateau detection =====
local recoverMinCS      = 120
local recoverMaxCS      = 450
local recoverLearnAlpha = 0.25
local plateauHoldCS     = 80
local plateauEpsV       = 0.004

-- ===== Cap tracking (OUTPUT ONLY) =====
-- SC4: capCell is NOT updated by a free-running window anymore.
-- It is updated ONLY on confirmed plateau recovery.
local capEmaAlpha      = 0.70
local capMargin        = 0.012
local idleCapMargin    = 0.02

-- ===== Buckets =====
local BUCKETS          = 16

-- ===== Sag learning =====
local minSagLearn      = 0.04
local maxSagPerCell    = 1.80
local minSagPerCell    = 0.00

-- Upward learning under load (fast)
local alphaUpCont      = 0.55
local alphaUpEvent     = 0.90

-- High-throttle shaping (prevents plateau)
local hiKneePct        = 0.70
local hiGamma          = 1.45

-- Voltage limits
local cellMin          = 2.50
local cellMax          = 4.35

-- ===== Decay (sag-table downward correction) =====
local downErrThreshV       = 0.060
local downConfirmEvents    = 6
local maxDownStepV         = 0.006
local downFracBase         = 0.03
local downFracMin          = 0.01
local downFracMax          = 0.08
local downFracUpStep       = 0.002
local downFracDnStep       = 0.001

-- ===== OCV-hold decay model (persisted) =====
local decayLearnAlpha      = 0.20
local decayScaleClampLo    = 0.60
local decayScaleClampHi    = 1.40
local decayMin_mVps        = 0.20
local decayMax_mVps        = 8.00

-- SC4: global slowdown of applied decay (does NOT affect learning math, only application)
-- Set lower to keep Sag stable for long WOT bursts.
local decayApplyFactor     = 0.20   -- 0.20 = 5x slower applied decay

local ocvFloorFromSag      = true
local ocvCeilUseCap        = true

-- ===== SD persistence settings =====
local persistEnabledDefault = true
local persistFolder         = "/SCRIPTS/DATA/"
local persistPrefix         = "SagComp_"
local persistVersion        = "SC4"
local saveIntervalCS        = 6000      -- 60s
local saveOnlyWhenLowThrPct = 0.12      -- save only near idle

-- ===== LiPo % table =====
local myArrayPercentList =
{{3,0},{3.093,1},{3.196,2},{3.301,3},{3.401,4},{3.477,5},{3.544,6},{3.601,7},{3.637,8},
{3.664,9},{3.679,10},{3.683,11},{3.689,12},{3.692,13},{3.705,14},{3.71,15},{3.713,16},
{3.715,17},{3.72,18},{3.731,19},{3.735,20},{3.744,21},{3.753,22},{3.756,23},{3.758,24},
{3.762,25},{3.767,26},{3.774,27},{3.78,28},{3.783,29},{3.786,30},{3.789,31},{3.794,32},
{3.797,33},{3.8,34},{3.802,35},{3.805,36},{3.808,37},{3.811,38},{3.815,39},{3.818,40},
{3.822,41},{3.825,42},{3.829,43},{3.833,44},{3.836,45},{3.84,46},{3.843,47},{3.847,48},
{3.85,49},{3.854,50},{3.857,51},{3.86,52},{3.863,53},{3.866,54},{3.87,55},{3.874,56},
{3.879,57},{3.888,58},{3.893,59},{3.897,60},{3.902,61},{3.906,62},{3.911,63},{3.918,64},
{3.923,65},{3.928,66},{3.939,67},{3.943,68},{3.949,69},{3.955,70},{3.961,71},{3.968,72},
{3.974,73},{3.981,74},{3.987,75},{3.994,76},{4.001,77},{4.007,78},{4.014,79},{4.021,80},
{4.029,81},{4.036,82},{4.044,83},{4.052,84},{4.062,85},{4.074,86},{4.085,87},{4.095,88},
{4.105,89},{4.111,90},{4.116,91},{4.12,92},{4.125,93},{4.129,94},{4.135,95},{4.145,96},
{4.176,97},{4.179,98},{4.193,99},{4.2,100}}

-- ===== helpers =====
local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi else return x end
end

local function ema(old, new, a)
  if old == nil then return new end
  return old + a * (new - old)
end

local function normalizeVoltage(v)
  if v == nil then return nil end
  if v > 50 then return v / 100.0 end
  return v
end

-- LiPo mapping (clamped): 4.20V/cell -> 100%
local function percentcell_lipo(v)
  if v == nil then return 0 end
  if v >= 4.20 then return 100 end
  if v <= 3.00 then return 0 end
  for _,p in ipairs(myArrayPercentList) do
    if p[1] >= v then return p[2] end
  end
  return 100
end

-- LiHV mapping:
-- - reserve headroom above 4.20 so 4.35 becomes 100%.
-- - 4.20 maps to ~95% and 4.35 maps to 100%.
local function percentcell_lihv(v)
  if v == nil then return 0 end
  if v >= 4.35 then return 100 end
  if v <= 3.00 then return 0 end
  if v <= 4.20 then
    local p = percentcell_lipo(v)
    return clamp(math.floor(p * 0.95 + 0.5), 0, 100)
  end
  local frac = (v - 4.20) / 0.15
  local p = 95 + frac * 5
  return clamp(math.floor(p + 0.5), 0, 100)
end

-- Chemistry-aware percent
local function percentcell(v, isLiHV)
  if isLiHV then
    return percentcell_lihv(v)
  end
  return percentcell_lipo(v)
end

local function thr01_from_value(thr)
  if thr == nil then return 0 end
  if thr > 800 and thr < 2200 then
    return clamp((thr - 1000) / 1000, 0, 1)
  else
    return clamp((thr + 1024) / 2048, 0, 1)
  end
end

local function ramp01(x, a, b)
  if b <= a then return (x > a) and 1 or 0 end
  if x <= a then return 0 elseif x >= b then return 1 else return (x - a)/(b - a) end
end

local function bucketIndex(thr01)
  local idx = math.floor(thr01 * BUCKETS) + 1
  if idx < 1 then idx = 1 end
  if idx > BUCKETS then idx = BUCKETS end
  return idx
end

local function bucketMid(i)
  return (i - 0.5) / BUCKETS
end

local function splitCSV(s)
  local t = {}
  if not s or s == "" then return t end
  for tok in string.gmatch(s, "([^,]+)") do
    t[#t+1] = tok
  end
  return t
end

-- ===== adaptive-rate tracking =====
local lastRxV, lastRxT, rxPeriodCS = 0, 0, fallbackUpdateCS
local function updateRxRate(now, v)
  if v ~= lastRxV then
    local dt = now - lastRxT
    if dt > 0 then rxPeriodCS = clamp(dt, minUpdateCS, maxUpdateCS) end
    lastRxV, lastRxT = v, now
  end
  return rxPeriodCS
end

-- ============================================================
-- SAFE SD persistence
-- ============================================================
local IO_OK =
  (type(io) == "table" and type(io.open) == "function" and
   type(io.read) == "function" and type(io.write) == "function" and
   type(io.close) == "function")

local function sanitizeName(name)
  if not name or name == "" then return "MODEL" end
  name = string.gsub(name, "%s+", "_")
  name = string.gsub(name, "[^%w_%-]", "_")
  if #name > 24 then name = string.sub(name, 1, 24) end
  return name
end

local function getModelNameSafe()
  if model and model.getInfo then
    local info = model.getInfo()
    if info and info.name and info.name ~= "" then
      return sanitizeName(info.name)
    end
  end
  return "MODEL"
end

local function persistPath()
  return persistFolder .. persistPrefix .. getModelNameSafe() .. ".dat"
end

local function readAll(path)
  if not IO_OK then return nil end
  local ok, out = pcall(function()
    local f = io.open(path, "r")
    if not f then return nil end
    local buf = ""
    while true do
      local chunk = io.read(f, 128)
      if not chunk or #chunk == 0 then break end
      buf = buf .. chunk
    end
    io.close(f)
    return buf
  end)
  if ok then return out end
  return nil
end

local function writeAll(path, text)
  if not IO_OK then return false end
  local ok, res = pcall(function()
    local f = io.open(path, "w")
    if not f then return false end
    io.write(f, text)
    io.close(f)
    return true
  end)
  return ok and res == true
end

-- ===== decay curve helpers =====
local function defaultDecay_mVps(i)
  local t = bucketMid(i)
  local mv = 0.25 + 1.95 * (t ^ 2.0)
  return clamp(mv, decayMin_mVps, decayMax_mVps)
end

local function mvps_to_Vcs(mvps)
  return mvps * 0.00001
end

local function Vcs_to_mvps(vcs)
  return vcs * 100000.0
end

-- ===== state =====
local st = {
  startCS=0, warmed=false, lastCS=0,

  inLow=false,
  lowTimer=0,
  lowPeakLong=nil,
  restStable=nil,

  recoverLearnCS = recoverDelayCSDefault,
  recovStartCS = 0,
  recovLastIncCS = 0,
  recovPeak = nil,
  recovPlateau = false,

  capCell=nil, -- SC4: updated ONLY at plateau

  episodeActive=false,
  episodeStarted=false,
  minByBucket={},

  sag={},
  downFrac={},
  downConfirm={},

  ocvEst=nil,
  ocvStart=nil,
  loadTimeByBucket={},
  decayVcs={},

  persistEnabled = persistEnabledDefault and IO_OK,
  persistLoaded  = false,
  persistDirty   = false,
  lastSaveCS     = 0,

  flyingSeen     = false,

  -- chemistry
  isLiHV = (chemistryMode == 2) and true or ((chemistryMode == 1) and false or nil),
  lihvDetectCnt = 0,
}

for i=1,BUCKETS do
  st.minByBucket[i]=nil
  st.sag[i]=nil
  st.downFrac[i]=downFracBase
  st.downConfirm[i]=0
  st.loadTimeByBucket[i]=0
  st.decayVcs[i]=mvps_to_Vcs(defaultDecay_mVps(i))
end

local function enforceMonotonicSag()
  local last=nil
  for i=1,BUCKETS do
    if st.sag[i]==nil and last~=nil then st.sag[i]=last end
    if st.sag[i]~=nil then last=st.sag[i] end
  end
  for i=2,BUCKETS do
    if st.sag[i]~=nil and st.sag[i-1]~=nil and st.sag[i] < st.sag[i-1] then
      st.sag[i] = st.sag[i-1]
    end
  end
end

local function extrapolateHighSag()
  local kneeIdx = bucketIndex(hiKneePct)
  local ref=nil
  for i=BUCKETS, kneeIdx, -1 do
    if st.sag[i] ~= nil then ref=i; break end
  end
  if ref == nil then return end

  local refThr = bucketMid(ref)
  if refThr <= 0 then return end

  for j=ref+1, BUCKETS do
    local t = bucketMid(j)
    local desired = st.sag[ref] * ((t / refThr) ^ hiGamma)
    desired = clamp(desired, minSagPerCell, maxSagPerCell)
    if st.sag[j] == nil or st.sag[j] < desired then
      st.sag[j] = desired
    end
  end
  enforceMonotonicSag()
end

local function sagEst(thr01)
  return st.sag[bucketIndex(thr01)] or 0.0
end

local function currentRecoverDelayCS()
  return clamp(math.floor(st.recoverLearnCS + 0.5), recoverMinCS, recoverMaxCS)
end

local function resetLoadEpisode()
  st.episodeStarted = false
  st.ocvStart = nil
  for i=1,BUCKETS do
    st.loadTimeByBucket[i] = 0
  end
end

-- ===== persistence: load once =====
local function persistLoadOnce()
  if not st.persistEnabled or st.persistLoaded then return end
  st.persistLoaded = true

  local ok = pcall(function()
    local data = readAll(persistPath())
    if not data or data == "" then return end

    local version = nil
    local bucketsOK = false
    local tmpSag, tmpDown, tmpDcr = {}, {}, {}
    local tmpRecover = nil
    local tmpChem = nil

    for line in string.gmatch(data, "([^\n]+)") do
      if line == "SC1" or line == "SC2" or line == "SC3" or line == "SC4" then
        version = line
      elseif string.sub(line, 1, 8) == "BUCKETS=" then
        local n = tonumber(string.sub(line, 9))
        bucketsOK = (n == BUCKETS)
      elseif string.sub(line, 1, 5) == "CHEM=" then
        tmpChem = string.sub(line, 6)
      elseif string.sub(line, 1, 4) == "SAG=" then
        local parts = splitCSV(string.sub(line, 5))
        for i=1,BUCKETS do
          local v = tonumber(parts[i] or "")
          if v and v >= 0 then tmpSag[i] = v end
        end
      elseif string.sub(line, 1, 5) == "DOWN=" then
        local parts = splitCSV(string.sub(line, 6))
        for i=1,BUCKETS do
          local v = tonumber(parts[i] or "")
          if v then tmpDown[i] = clamp(v, downFracMin, downFracMax) end
        end
      elseif string.sub(line, 1, 7) == "RECOV=" then
        local v = tonumber(string.sub(line, 8))
        if v then tmpRecover = v end
      elseif string.sub(line, 1, 4) == "DCR=" then
        local parts = splitCSV(string.sub(line, 5))
        for i=1,BUCKETS do
          local v = tonumber(parts[i] or "")
          if v then tmpDcr[i] = clamp(v, decayMin_mVps, decayMax_mVps) end
        end
      end
    end

    if not version or not bucketsOK then return end

    for i=1,BUCKETS do
      st.sag[i] = tmpSag[i]
      st.downFrac[i] = tmpDown[i] or downFracBase
      st.downConfirm[i] = 0
      if tmpDcr[i] then st.decayVcs[i] = mvps_to_Vcs(tmpDcr[i]) end
    end

    if tmpRecover then st.recoverLearnCS = clamp(tmpRecover, recoverMinCS, recoverMaxCS) end

    -- Restore chemistry if AUTO mode and value exists
    if chemistryMode == 0 and tmpChem then
      if tmpChem == "LIHV" then st.isLiHV = true end
      if tmpChem == "LIPO" then st.isLiHV = false end
    end

    enforceMonotonicSag()
    extrapolateHighSag()
  end)

  if not ok then st.persistEnabled = false end
end

-- ===== persistence: save =====
local function persistSaveIfNeeded(now, thr01)
  if not st.persistEnabled then return end
  if not st.persistDirty then return end
  if not st.flyingSeen then return end
  if thr01 > saveOnlyWhenLowThrPct then return end
  if (now - st.lastSaveCS) < saveIntervalCS then return end

  local ok = pcall(function()
    local s = {}
    for i=1,BUCKETS do
      if st.sag[i] == nil then s[#s+1] = "-1" else s[#s+1] = string.format("%.4f", st.sag[i]) end
    end
    local d = {}
    for i=1,BUCKETS do
      d[#d+1] = string.format("%.4f", st.downFrac[i] or downFracBase)
    end
    local dc = {}
    for i=1,BUCKETS do
      dc[#dc+1] = string.format("%.4f",
        clamp(Vcs_to_mvps(st.decayVcs[i] or mvps_to_Vcs(defaultDecay_mVps(i))), decayMin_mVps, decayMax_mVps))
    end

    local chemStr = "AUTO"
    if st.isLiHV == true then chemStr = "LIHV" end
    if st.isLiHV == false then chemStr = "LIPO" end

    local text =
      persistVersion .. "\n" ..
      "BUCKETS=" .. tostring(BUCKETS) .. "\n" ..
      "RECOV=" .. tostring(currentRecoverDelayCS()) .. "\n" ..
      "CHEM=" .. chemStr .. "\n" ..
      "SAG=" .. table.concat(s, ",") .. "\n" ..
      "DOWN=" .. table.concat(d, ",") .. "\n" ..
      "DCR=" .. table.concat(dc, ",") .. "\n"

    if writeAll(persistPath(), text) then
      st.persistDirty = false
      st.lastSaveCS = now
    else
      st.persistEnabled = false
    end
  end)

  if not ok then st.persistEnabled = false end
end

-- ===== sag update funcs =====
local function updateSagUpOnly(i, cand)
  cand = clamp(cand, minSagPerCell, maxSagPerCell)
  local cur = st.sag[i]
  if cur == nil then st.sag[i] = cand; st.persistDirty = true; return end
  if cand > cur then
    local newv = cur + alphaUpCont * (cand - cur)
    if newv ~= cur then st.sag[i] = newv; st.persistDirty = true end
  end
end

local function updateSagOnRecovery(i, cand)
  cand = clamp(cand, minSagPerCell, maxSagPerCell)
  local cur = st.sag[i]
  if cur == nil then st.sag[i] = cand; st.downConfirm[i]=0; st.persistDirty=true; return end

  if cand >= cur then
    local newv = cur + alphaUpEvent * (cand - cur)
    if newv ~= cur then st.sag[i] = newv; st.persistDirty = true end
    st.downConfirm[i] = 0
    local nf = clamp(st.downFrac[i] - downFracDnStep, downFracMin, downFracMax)
    if nf ~= st.downFrac[i] then st.downFrac[i] = nf; st.persistDirty = true end
    return
  end

  local diff = cur - cand
  if diff <= downErrThreshV then
    st.downConfirm[i] = 0
    local nf = clamp(st.downFrac[i] - downFracDnStep, downFracMin, downFracMax)
    if nf ~= st.downFrac[i] then st.downFrac[i] = nf; st.persistDirty = true end
    return
  end

  st.downConfirm[i] = st.downConfirm[i] + 1
  local nf = clamp(st.downFrac[i] + downFracUpStep, downFracMin, downFracMax)
  if nf ~= st.downFrac[i] then st.downFrac[i] = nf; st.persistDirty = true end
  if st.downConfirm[i] < downConfirmEvents then return end

  local step = diff * st.downFrac[i]
  if step > maxDownStepV then step = maxDownStepV end
  local newSag = cur - step
  if newSag ~= cur then st.sag[i] = newSag; st.persistDirty = true end
  st.downConfirm[i] = math.floor(downConfirmEvents * 0.5)
end

-- ===== decay learning from recovery =====
local function learnDecayFromRecovery(restRef)
  if st.ocvStart == nil then return end

  local neededDelta = st.ocvStart - restRef
  if neededDelta < 0 then neededDelta = 0 end

  local predictedDelta = 0.0
  local anyTime = false
  for i=1,BUCKETS do
    local t = st.loadTimeByBucket[i] or 0
    if t > 0 then
      anyTime = true
      predictedDelta = predictedDelta + (st.decayVcs[i] or 0) * t
    end
  end
  if not anyTime then return end
  if predictedDelta < 0.001 or neededDelta < 0.001 then return end

  local scale = clamp(neededDelta / predictedDelta, decayScaleClampLo, decayScaleClampHi)
  local changed = false

  for i=1,BUCKETS do
    local t = st.loadTimeByBucket[i] or 0
    if t > 0 then
      local mvps = clamp(Vcs_to_mvps(st.decayVcs[i]), decayMin_mVps, decayMax_mVps)
      local target = mvps * scale
      local newmv = mvps + decayLearnAlpha * (target - mvps)
      newmv = clamp(newmv, decayMin_mVps, decayMax_mVps)
      local newvcs = mvps_to_Vcs(newmv)
      if newvcs ~= st.decayVcs[i] then st.decayVcs[i] = newvcs; changed = true end
    end
  end

  if changed then st.persistDirty = true end
end

-- ===== SC4: capCell update ONLY on plateau recovery =====
local function updateCapFromRecovery(restRef)
  if restRef == nil then return end
  local old = st.capCell
  st.capCell = ema(st.capCell, restRef, capEmaAlpha)
  if old == nil or st.capCell ~= old then st.persistDirty = true end
end

-- ===== chemistry auto-detect =====
local function updateChemistry(cellRaw, thr01)
  if chemistryMode == 1 then
    if st.isLiHV ~= false then st.isLiHV = false; st.persistDirty = true end
    st.lihvDetectCnt = 0
    return
  end
  if chemistryMode == 2 then
    if st.isLiHV ~= true then st.isLiHV = true; st.persistDirty = true end
    st.lihvDetectCnt = 0
    return
  end

  -- Auto
  if st.isLiHV == true then
    st.lihvDetectCnt = 0
    return
  end

  -- Detect only at low throttle (rest zone) to avoid sag/noise; require consecutive samples.
  if thr01 <= thrRestPct and cellRaw >= lihvDetectV then
    st.lihvDetectCnt = st.lihvDetectCnt + 1
    if st.lihvDetectCnt >= lihvDetectSamplesNeed then
      st.isLiHV = true
      st.persistDirty = true
      st.lihvDetectCnt = 0
    end
  else
    st.lihvDetectCnt = 0
  end
end

-- ===== main run() =====
local function run()
  if thrRampEndPct <= thrNoCompPct then thrRampEndPct = thrNoCompPct + 0.15 end

  local now = getTime()
  local rxRaw = getValue(myBatSensorName)
  if not rxRaw or rxRaw == 0 then return 0 end

  if st.startCS == 0 then st.startCS = now end
  if not st.warmed then
    if (now - st.startCS) < warmupDelayCS then return 0 end
    st.warmed = true
    st.lastCS = now
    st.lastSaveCS = now
    persistLoadOnce()
  end

  local dt = now - st.lastCS
  local period = adaptiveRate and updateRxRate(now, rxRaw) or fallbackUpdateCS
  if dt < period then return 0 end
  st.lastCS = now

  local packV = normalizeVoltage(rxRaw)
  local cellCount = math.ceil(packV / 4.35); if cellCount < 1 then cellCount = 1 end
  local cellRaw = clamp(packV / cellCount, cellMin, cellMax)

  local thr01 = thr01_from_value(getValue(myThrSourceName))

  -- Chemistry detection (for BatP mapping)
  updateChemistry(cellRaw, thr01)

  -- initialize capCell once (prevents nil on first flight if you never idle long)
  if st.capCell == nil then st.capCell = cellRaw end

  local ratio = ramp01(thr01, thrNoCompPct, thrRampEndPct)
  local ratioPct = math.floor(ratio * 100 + 0.5)
  setTelemetryValue(0x0310, 0, 4, ratioPct, 13, 0, myRatioName)

  -- ===== Low-throttle recovery tracking (plateau + adaptive RECOV learning) =====
  if thr01 <= thrRestPct then
    if not st.inLow then
      st.inLow = true
      st.lowTimer = 0
      st.lowPeakLong = cellRaw
      st.recovStartCS = now
      st.recovLastIncCS = now
      st.recovPeak = cellRaw
      st.recovPlateau = false
    end

    st.lowTimer = st.lowTimer + dt
    if cellRaw > st.lowPeakLong then st.lowPeakLong = cellRaw end

    if cellRaw > (st.recovPeak or cellRaw) + plateauEpsV then
      st.recovPeak = cellRaw
      st.recovLastIncCS = now
    else
      if (now - st.recovLastIncCS) >= plateauHoldCS and st.lowTimer >= recoverMinCS then
        st.recovPlateau = true
      end
    end

    local dynRecoverCS = currentRecoverDelayCS()
    if st.recovPlateau and st.lowTimer >= dynRecoverCS and st.lowPeakLong ~= nil then
      -- Learn recovery time if we saw load
      if st.episodeActive or st.flyingSeen then
        local measured = clamp(now - st.recovStartCS, recoverMinCS, recoverMaxCS)
        local old = currentRecoverDelayCS()
        st.recoverLearnCS = ema(st.recoverLearnCS, measured, recoverLearnAlpha)
        local newv = currentRecoverDelayCS()
        if newv ~= old then st.persistDirty = true end
      end

      -- restStable + SC4 capCell update ONLY here
      st.restStable = ema(st.restStable, st.lowPeakLong, lowPeakEmaAlpha)
      updateCapFromRecovery(st.lowPeakLong)

      if st.episodeActive then
        local restRef = st.lowPeakLong

        learnDecayFromRecovery(restRef)

        for i=1,BUCKETS do
          local vmin = st.minByBucket[i]
          if vmin ~= nil then
            local candSag = restRef - vmin
            if candSag >= minSagLearn then
              updateSagOnRecovery(i, candSag)
              st.flyingSeen = true
            end
          end
          st.minByBucket[i] = nil
        end

        st.episodeActive = false
        enforceMonotonicSag()
        extrapolateHighSag()

        st.ocvEst = restRef
        resetLoadEpisode()
      end
    end
  else
    st.inLow = false
    st.lowTimer = 0
    st.lowPeakLong = nil
    st.recovStartCS = 0
    st.recovLastIncCS = 0
    st.recovPeak = nil
    st.recovPlateau = false
  end

  -- ===== Capture minima under load + start OCV-hold episode =====
  if thr01 >= thrCapturePct then
    if not st.episodeActive then
      st.episodeActive = true
      st.episodeStarted = false
      for i=1,BUCKETS do st.loadTimeByBucket[i] = 0 end
    end

    local b = bucketIndex(thr01)
    local prev = st.minByBucket[b]
    if prev == nil or cellRaw < prev then st.minByBucket[b] = cellRaw end

    if not st.episodeStarted then
      local ref = st.capCell or st.restStable or cellRaw
      st.ocvStart = clamp(ref, cellMin, cellMax)
      st.ocvEst = st.ocvStart
      st.episodeStarted = true
    end

    st.loadTimeByBucket[b] = (st.loadTimeByBucket[b] or 0) + dt

    -- SC4: apply decay much slower (decayApplyFactor)
    local dV = (st.decayVcs[b] or 0) * dt * decayApplyFactor
    st.ocvEst = clamp((st.ocvEst or cellRaw) - dV, cellMin, cellMax)

    -- Floor OCV using sag model (keeps Sag stable even if raw droops hard)
    if ocvFloorFromSag then
      local ocvFromSag = cellRaw + (sagEst(thr01) * ratio)
      if ocvFromSag > st.ocvEst then st.ocvEst = ocvFromSag end
    end

    -- Ceiling using capCell (now reliable)
    if ocvCeilUseCap and st.capCell ~= nil then
      local hardCap = st.capCell + capMargin
      if st.ocvEst > hardCap then st.ocvEst = hardCap end
    end
  end

  -- ===== Continuous UP-only sag shaping under load =====
  if st.restStable ~= nil and thr01 >= thrCapturePct then
    local candSag = st.restStable - cellRaw
    if candSag >= minSagLearn then
      local b = bucketIndex(thr01)
      updateSagUpOnly(b, candSag)
      enforceMonotonicSag()
      extrapolateHighSag()
      st.flyingSeen = true
    end
  end

  -- ===== Output =====
  local capOut = st.capCell
  local cellComp = cellRaw

  if thr01 <= thrNoCompPct and capOut ~= nil then
    cellComp = capOut
  else
    if st.ocvEst ~= nil and thr01 >= thrCapturePct then
      cellComp = clamp(st.ocvEst, cellRaw, cellMax)
    else
      local sag = sagEst(thr01) * ratio
      cellComp = clamp(cellRaw + sag, cellMin, cellMax)
    end

    if capOut ~= nil and thr01 < thrRampEndPct then
      local capBand = capOut + idleCapMargin
      if cellComp > capBand then cellComp = capBand end
    end
  end

  if capOut ~= nil then
    local hardCap = capOut + capMargin
    if cellComp > hardCap then cellComp = hardCap end
  end

  if cellComp < cellRaw then cellComp = cellRaw end

  -- BatP: chemistry-aware mapping (LiPo vs LiHV)
  local batPct = percentcell(cellComp, st.isLiHV == true)

  setTelemetryValue(0x0310, 0, 1, batPct, 13, 0, myBatPercentName)
  setTelemetryValue(0x0310, 0, 2, math.floor(cellComp * 10 + 0.5), 1, 1, mySagCellName)
  setTelemetryValue(0x0310, 0, 3, math.floor(cellRaw  * 10 + 0.5), 1, 1, myRawCellName)

  persistSaveIfNeeded(now, thr01)

  return batPct * 10, 24
end

return { run = run }
