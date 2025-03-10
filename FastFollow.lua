_addon.name = 'FastFollow'
_addon.author = 'PBW Modified'
_addon.version = '5.3.0'
_addon.commands = {'fastfollow', 'ffo'}

require('strings')
require('tables')
require('sets')
require('coroutine')
local socket = require('socket')
packets = require('packets')
res = require('resources')
items = res.items
config = require('config')
texts = require('texts')
require('logger')
require('strings')
require('vectors')

follow_me = 0
following = false
target = nil
last_target = nil
min_dist = 0.5^2
max_dist = 50.0^2
repeated = false
running = false
local lastUpdTime = 0
local lastZonePosUpdTime = 0
-- Global position update interval in milliseconds
local updateIntervalMsec = 50
-- Zoning only position update interval in milliseconds
local zonePosUpdateInterval = 3000


__should_attempt_to_cross_zone_line = false
__zone_begin = false
__last_x = 0
__last_y = 0
__last_z = 0
__engage = false
__in_mog_house = false
job_registry= T{}

windower.register_event('unload', function()
  windower.send_command('ffo stop')
  coroutine.sleep(0.25) -- Reduce crash on reload, since Windower seems to crash if IPC messages are received as it's restarting.
end)

windower.register_event('addon command', function(command, ...)
  command = command and command:lower() or nil
  args = T{...}
  
  if not command then
    log('Provide a name to follow, or "me" to make others follow you.')
    log('Stop following with "stop" on a single character, or "stopall" on all characters.')
  elseif command == 'followme' or command == 'me' or command == 'on' then
    self = windower.ffxi.get_mob_by_target('me')
    if not self and not repeated then
      repeated = true
	  min_dist = 0.5^2
      windower.send_command('@wait 1; ffo followme')
      return
    end
    repeated = false
    windower.send_ipc_message('follow '..self.name)
	windower.add_to_chat(5, '[FFO]: All follow leader: '..self.name)
  elseif command == 'stop' or command == 'foff' then
    if following then windower.send_ipc_message('stopfollowing '..following) end
    following = false
    windower.add_to_chat(5, '[FFO]: Stop follow.')
  elseif command == 'stopall' then
    follow_me = 0
    following = false
    windower.send_ipc_message('stop')
	windower.add_to_chat(5, '[FFO]: All Stop.')
  elseif command == 'follow' or command == 'f' then
    if #args == 0 then
      return windower.add_to_chat(123, '[FFO]: You must provide a player name to follow.')
    end
	follow_me = 0
    following = false
    following = args[1]:lower()
	--Do check here if it's valid name but kinda stupid because can only follow your chars?
    windower.send_ipc_message('following '..following)
    windower.ffxi.follow()
	windower.add_to_chat(5, '[FFO]: Following: '..following)
  elseif command =='followjob' or command == 'fjob' then
	if #args == 0 then
      return windower.add_to_chat(123, '[FFO]: You must provide a JOB to follow.')
    end
	follow_me = 0
    following = false
    following = args[1]:lower()
	local pname = getPlayerNameFromJob(following)
	if (pname ~= nil) then
		local lowername = pname:lower()
		following = lowername
	    windower.send_ipc_message('following '..lowername)
		windower.ffxi.follow()
		windower.add_to_chat(5, '[FFO]: Following: '..pname..' - '..following:upper())
    else
		windower.add_to_chat(123,'Error: Invalid JOB provided as a follow target: '..tostring(args[1]))
    end
  elseif command == 'min' or command == 'dist' then
    local dist = tonumber(args[1])
    if not dist then return end
    
    dist = math.min(math.max(0.2, dist), 50.0)
	windower.add_to_chat(5, '[FFO]: Distance: '..dist)
    min_dist = dist^2
  elseif command == 'engage' then
	if not __engage then
		__engage = true
		windower.add_to_chat(5, '[FFO]: Follow while engaged ON')
	else
		__engage = false
		windower.add_to_chat(5, '[FFO]: Follow while engaged OFF')
	end
  elseif command and #args == 0 then
    windower.send_command('ffo follow '..command)
  end
end)

windower.register_event('ipc message', function(msgStr)
  local args = msgStr:lower():split(' ')
  local command = args:remove(1)
  
  if command == 'stop' then
    follow_me = 0
    following = false
    windower.ffxi.run(false)
  elseif command == 'follow' then
    if following then windower.send_ipc_message('stopfollowing '..following) end
	follow_me = 0
    following = false
    following = args[1]
    windower.send_ipc_message('following '..following)
    windower.ffxi.follow()
	windower.add_to_chat(5, '[FFO]: IPC Follow: '..following)
  elseif command == 'following' then
    self = windower.ffxi.get_player()
    if not self or self.name:lower() ~= args[1] then return end
    follow_me = follow_me + 1
  elseif command == 'stopfollowing' then
    self = windower.ffxi.get_player()
    if not self or self.name:lower() ~= args[1] then return end
    follow_me = math.max(follow_me - 1, 0)
  elseif command == 'update' then
    local pos = {x=tonumber(args[3]), y=tonumber(args[4])}
    
    if not following or args[1] ~= following then return end
    
    target = {x=pos.x, y=pos.y, zone=tonumber(args[2])}
    
    if not last_target then last_target = target end
    
    if target.zone ~= -1 and (target.x ~= last_target.x or target.y ~= last_target.y or target.zone ~= last_target.zone) then
		last_target = target
    end
  elseif command == 'follow_zone' then	-- For follow to zoneline
	if following and following == args[1] and tonumber(args[2]) == windower.ffxi.get_info().zone then
		windower.add_to_chat(5, '[FFO]: IPC Run to zone.')
		__last_x = args[3]
		__last_y = args[4]
		__last_z = args[5]
		__should_attempt_to_cross_zone_line = true
	end			
  end
end)

windower.register_event('prerender', function()	
	local timeMsec = socket.gettime() * 1000
	if timeMsec - lastUpdTime < updateIntervalMsec then return end
	lastUpdTime = timeMsec

	if not follow_me and not following then return end
	local player = windower.ffxi.get_player()
	
	  
	if follow_me > 0 then
		local self = windower.ffxi.get_mob_by_target('me')
		local info = windower.ffxi.get_info()

		if not self or not info then return end

		args = T{'update', self.name , info.zone, self.x, self.y}
		windower.send_ipc_message(args:concat(' '))
	elseif following then
		local self = windower.ffxi.get_mob_by_target('me')
		local info = windower.ffxi.get_info()
		
		if not self or not info then return end
		if __in_mog_house then return end
	   
		if not target then
			if running and (__engage or (not __engage and player.status ~= 1)) then
				windower.ffxi.run(false)
				running = false
			end
			return
		end

		distSq = distanceSquared(target, self)
		len = math.sqrt(distSq)
		if len < 1 then len = 1 end
		
		if __should_attempt_to_cross_zone_line then -- zone
			
			if timeMsec - lastZonePosUpdTime < zonePosUpdateInterval then return end
			lastZonePosUpdTime = timeMsec

			-- Add a distance offset along the vector direction
			local p = windower.ffxi.get_mob_by_target('me')
			local direction_vector = V{__last_x - p.x, __last_y - p.y, __last_z - p.z}
			local distance_offset = 3 -- Set this to the distance you want to add (e.g., +1 or +2)

			-- Normalize the direction vector and scale it by the offset distance
			local unit_vector = direction_vector:normalize() * distance_offset

			-- Calculate the new position by adding the scaled vector
			local adjusted_x = __last_x + unit_vector[1]
			local adjusted_y = __last_y + unit_vector[2]
			local adjusted_z = __last_z + unit_vector[3]
			
			-- Calculate the distance from the current position to the adjusted position
			local distance_to_adjusted = (V{adjusted_x - p.x, adjusted_y - p.y, adjusted_z - p.z}):length()

			-- Add a check for the distance
			if distance_to_adjusted > 40 then
				windower.add_to_chat(5, '[FFO]: Adjusted position is too far: ' .. distance_to_adjusted .. '. Aborting.')
				running = false
				__should_attempt_to_cross_zone_line = false
				return
			else
				windower.add_to_chat(5, '[FFO]: Adjusted position for zone: X: ' .. adjusted_x .. 'Y: ' .. adjusted_y .. '.')
				run_to_pos(adjusted_x, adjusted_y, adjusted_z)
				running = true
				return
			end
		end
		
		if target.zone == info.zone and distSq > min_dist and distSq < max_dist and (__engage or (not __engage and player.status ~= 1)) then --  and player.status ~= 1
			windower.ffxi.run((target.x - self.x)/len, (target.y - self.y)/len)
			running = true
		elseif target.zone == info.zone and distSq <= min_dist and not __should_attempt_to_cross_zone_line and (__engage or (not __engage and player.status ~= 1)) then
			windower.ffxi.run(false)
			running = true
		elseif running and (__engage or (not __engage and player.status ~= 1)) then
			windower.ffxi.run(false)
			running = false
		end
	end
end)

function distanceSquared(A, B)
	local dx = B.x-A.x
	local dy = B.y-A.y
	return dx*dx + dy*dy
end

function run_to_pos(tx,ty,tz, min_distance)
	min_distance = min_distance or 0.2
	
	local p = windower.ffxi.get_mob_by_target('me')

	windower.ffxi.run(tx-p.x, ty-p.y)
	p_2 = windower.ffxi.get_mob_by_index(p.index)
	
	while p_2 and ((V{p_2.x, p_2.y, (p_2.z*-1)} - V{tx, ty, (tz*-1)}):length()) >= min_distance do
		p_2 = windower.ffxi.get_mob_by_index(p.index)
		if p_2 then
			windower.ffxi.run(tx-p_2.x, ty-p_2.y)
		end
		coroutine.sleep(0.15)
	end
	windower.ffxi.run(false)
end

function getPlayerNameFromJob(job)
	local target
	for k, v in pairs(windower.ffxi.get_party()) do
		if type(v) == 'table' and v.mob ~= nil and v.mob.in_party then
			if ((job:lower() == 'tank' and S{'PLD','RUN'}:contains(get_registry(v.mob.id))) or (job:lower() ~= 'tank' and get_registry(v.mob.id):lower() == job:lower())) then
				target = v.name
			end
		end
	end
    if target ~= nil then
        return target
    end
    return nil
end

function set_registry(id, job_id)
    if not id then return false end
    job_registry[id] = job_registry[id] or 'NON'
    job_id = job_id or 0
    if res.jobs[job_id].ens == 'NON' and job_registry[id] and not S{'NON', 'UNK'}:contains(job_registry[id]) then 
        return false
    end
    job_registry[id] = res.jobs[job_id].ens
    return true
end

function get_registry(id)
    if job_registry[id] then
		return job_registry[id]
    else
        return 'UNK'
    end
end

function handle_incoming_chunk(id, data)
	if id == 0x00B then 
		if __zone_begin and follow_me > 0 then
			log('0x00B: packet for zone NOW.')
			local orig_zone = windower.ffxi.get_info().zone
			local self = windower.ffxi.get_mob_by_target('me')
			local myself = string.lower(windower.ffxi.get_player().name)
			local response = "follow_zone "..myself.." "..orig_zone.." "..self.x.." "..self.y.." "..self.z
			windower.send_ipc_message(response)
		else
			log('0x00B: Unset zone run.')
			__should_attempt_to_cross_zone_line = false
		end
	elseif (id == 0x0DD or id == 0x0DF or id == 0x0C8) then	--Party member update
        local parsed = packets.parse('incoming', data)
		if parsed then
			local playerId = parsed['ID']
			local indexx = parsed['Index']
			local job = parsed['Main job']
			
			if playerId and playerId > 0 then
				set_registry(parsed['ID'], parsed['Main job'])
			end
		end
	elseif id == 0x00A then
		__in_mog_house = data:byte(0x81) == 1
    end
end

function handle_outgoing_chunk(id, data)
	if id == 0x05E and follow_me > 0 then
		if not __in_mog_house then
			windower.add_to_chat(5, '[FFO]: 0x05E: Leader request to zone.')
			__zone_begin = true
		end
	end
end

function handle_zone(new_id, old_id)
	__should_attempt_to_cross_zone_line = false
	__zone_begin = false
	__last_x = 0
	__last_y = 0
	__last_z = 0
    zone_info = windower.ffxi.get_info()
end

windower.register_event('zone change', handle_zone)
windower.register_event('incoming chunk', handle_incoming_chunk)
windower.register_event('outgoing chunk', handle_outgoing_chunk)