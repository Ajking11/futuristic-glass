-- Refactored Extreme Reactor Monitor with PID Control, Energy Overflow Prevention, and Backup Activation

-- Detect peripherals
local reactors = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "ExtremeReactors_Reactor" then
    table.insert(reactors, peripheral.wrap(name))
  end
end

if #reactors == 0 then
  error("No reactors found! Connect reactors via Computer Ports.")
end

local monitors = {peripheral.find("monitor")}
local hasMonitors = #monitors > 0

local wirelessModem = peripheral.find("modem", function(name, modem)
  return modem.isWireless()
end)
local hasWireless = wirelessModem ~= nil
if hasWireless then
  rednet.open(peripheral.getName(wirelessModem))
end

local hasRedstone = false
for _, side in ipairs({"left", "right", "front", "back", "top", "bottom"}) do
  if redstone.getSides()[side] then
    hasRedstone = true
    break
  end
end

-- Configuration
local config = {
  maxTemperature = 2000,        -- Shutdown temperature (Celsius)
  monitorInterval = 5,          -- Seconds between updates
  backupThreshold = 0.1,        -- Energy level to trigger backups
  overflowThreshold = 0.95,     -- Energy level to pause reactor
  logToFile = true,             -- Enable/Disable logging
  logFileName = "reactor_log.txt", -- Log file name
  pid = {                       -- PID Controller Settings
    kP = 2,   -- Proportional gain
    kI = 0.1, -- Integral gain
    kD = 1    -- Derivative gain
  }
}

-- PID state
local pidState = {previousError = 0, integral = 0}

-- Helper: Clamp values
local function clamp(value, min, max)
  return math.max(min, math.min(max, value))
end

-- Helper: Write to monitors dynamically
local function writeToMonitors(lines)
  if not hasMonitors then return end
  for _, monitor in ipairs(monitors) do
    monitor.clear()
    local width, height = monitor.getSize()
    for i, line in ipairs(lines) do
      if i <= height then
        monitor.setCursorPos(1, i)
        monitor.write(line:sub(1, width)) -- Truncate long lines
      end
    end
  end
end

-- Helper: Log reactor stats to a file
local function logStats(stats)
  if not config.logToFile then return end
  local file = fs.open(config.logFileName, "a")
  if file then
    file.writeLine(string.format(
      "[%s] Reactor: %s | Energy: %d RF | Temp: %.1f°C",
      textutils.formatTime(os.time(), true),
      stats.reactorName,
      stats.energyStored,
      stats.fuelTemp
    ))
    file.close()
  end
end

-- PID controller for control rod adjustments
local function pidController(target, actual)
  local error = target - actual
  pidState.integral = pidState.integral + error
  local derivative = error - pidState.previousError
  pidState.previousError = error

  -- Calculate PID output
  local output = (config.pid.kP * error) +
                 (config.pid.kI * pidState.integral) +
                 (config.pid.kD * derivative)
  return clamp(output, -100, 100) -- Limit adjustments to valid rod levels
end

-- Adjust control rods using PID
local function adjustControlRods(stats, reactor)
  local energyPercentage = stats.energyStored / stats.energyCapacity
  local target = 0.9 -- Maintain 90% buffer by default
  local adjustment = pidController(target, energyPercentage)

  -- Adjust control rods based on PID output
  local newLevel = clamp(stats.controlRodLevel + adjustment, 0, 100)
  reactor.setAllControlRodLevels(newLevel)
  print(string.format("Adjusted rods for %s: %d%% (PID Adjustment: %.2f)", stats.reactorName, newLevel, adjustment))
end

-- Reset PID state (e.g., after shutdown)
local function resetPidState()
  pidState.previousError = 0
  pidState.integral = 0
end

-- Main monitoring and control loop
while true do
  for _, reactor in ipairs(reactors) do
    -- Get reactor stats
    local stats = {
      reactorName = peripheral.getName(reactor),
      energyStored = reactor.getEnergyStored(),
      energyCapacity = reactor.getEnergyCapacity(),
      fuelTemp = reactor.getFuelTemperature(),
      caseTemp = reactor.getCasingTemperature(),
      fuelAmount = reactor.getFuelAmount(),
      wasteAmount = reactor.getWasteAmount(),
      controlRodLevel = reactor.getControlRodLevel(0),
      reactorActive = reactor.getActive()
    }

    -- Energy Overflow Prevention
    local energyPercentage = stats.energyStored / stats.energyCapacity
    if energyPercentage > config.overflowThreshold then
      if stats.reactorActive then
        reactor.setActive(false)
        writeToMonitors({"Reactor Paused: Energy buffer full."})
        print("Reactor paused: Energy buffer is at " .. (energyPercentage * 100) .. "%.")
      end
    elseif not stats.reactorActive and energyPercentage < config.overflowThreshold - 0.1 then
      reactor.setActive(true)
      print("Reactor resumed: Energy buffer below threshold.")
    end

    -- Backup Power Activation
    if energyPercentage < config.backupThreshold then
      if hasRedstone then
        redstone.setOutput("right", true) -- Activate backup
        print("Backup system activated: Energy buffer critical.")
      end
    else
      if hasRedstone then
        redstone.setOutput("right", false) -- Deactivate backup
      end
    end

    -- Handle overheating
    if stats.fuelTemp > config.maxTemperature then
      reactor.setActive(false)
      writeToMonitors({"WARNING: Reactor Overheating!", "Shutting down for safety!"})
      if hasWireless then
        rednet.broadcast("Reactor Overheating! Shutdown initiated.", "reactorAlert")
      end
      error("Reactor shutdown due to overheating.")
    end

    -- Adjust control rods using PID
    adjustControlRods(stats, reactor)

    -- Display stats
    local lines = {
      string.format("Reactor: %s", stats.reactorName),
      string.format("Energy: %d RF (%.1f%%)", stats.energyStored, energyPercentage * 100),
      string.format("Fuel Temp: %.1f°C", stats.fuelTemp),
      string.format("Casing Temp: %.1f°C", stats.caseTemp),
      string.format("Fuel: %.1f mB", stats.fuelAmount),
      string.format("Waste: %.1f mB", stats.wasteAmount),
      string.format("Rod Level: %d%%", stats.controlRodLevel),
      string.format("Active: %s", stats.reactorActive and "Yes" or "No")
    }
    writeToMonitors(lines)

    -- Log stats
    logStats(stats)
  end
  sleep(config.monitorInterval)
end
