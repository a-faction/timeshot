local pairs = pairs
local error = error
local tonumber = tonumber
local tostring = tostring
local table = table
local print = print
local ipairs = ipairs


module "irc"

handlers = {}

handlers["PING"] = function(o, prefix, query) o:send("PONG :%s", query) end

handlers["001"] = function(o, prefix, me)
    o.authed = true
    o.nick = me
end

handlers["PRIVMSG"] = function(o, prefix, channel, message)
	-- if o.channels[channel] ~= nil then
    --     for k, v in ipairs(o) do
    --         print('vovacha '..k)
    --     end
	-- end
    
    -- print('++ message? '..tostring(o))
    local user = parsePrefix(prefix)
    -- print('ONICK '..o.nick..' channel!!! '..channel..' PRWFEFIXXXXXXX '..prefix..' user '..user.nick)
    local www = nil
    if o.channels[channel] ~= nil and o.channels[channel].users[user.nick] ~= nil then
        print('CHECK ACCESS! {} jaba222222???? '..tostring(o.channels[channel].users[user.nick].access.voice))
        www = o.channels[channel].users[user.nick].access.voice
    end
    o:invoke("OnChat", parsePrefix(prefix), channel, message, o, rank)
end

handlers["NOTICE"] = function(o, prefix, channel, message)
    o:invoke("OnNotice", parsePrefix(prefix), channel, message)
end

handlers["JOIN"] = function(o, prefix, channel)
    local user = parsePrefix(prefix)
	print('PREFIX: '..prefix)
    if o.track_users then
		print('user.nick '..tostring(user[1])..' o.nick '..tostring(o.nick))
        if user.nick == o.nick then
            o.channels[channel] = {users = {user.nick}}
            o.channels[channel].users[user.nick] = user
			print('++++ '..tostring(table.concat(o.channels[channel].users,',')))
        else
            o.channels[channel].users[user.nick] = user
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
			print('+++++++++++ '..tostring(o.channels[channel].users[user.nick]))
        end
    end
	print(')_@#T()J@#FG()')
    o:invoke("OnJoin", user, channel)
end

handlers["PART"] = function(o, prefix, channel, reason)
    local user = parsePrefix(prefix)
    if o.track_users then
        if user.nick == o.nick then
            o.channels[channel] = nil
        else
            o.channels[channel].users[user.nick] = nil
        end
    end
    o:invoke("OnPart", user, channel, reason)
end

handlers["QUIT"] = function(o, prefix, msg)
    local user = parsePrefix(prefix)
    if o.track_users then
        for channel, v in pairs(o.channels) do v.users[user.nick] = nil end
    end
    o:invoke("OnQuit", user, msg)
end

handlers["NICK"] = function(o, prefix, newnick)
    local user = parsePrefix(prefix)
    if o.track_users then
        for channel, v in pairs(o.channels) do
            local users = v.users
			print('v.users >>'..tostring(v.users))
            local oldinfo = users[user.nick]
            if oldinfo then
                users[newnick] = oldinfo
                users[user.nick] = nil
                o:invoke("NickChange", user, newnick, channel)
            end
        end
    else
        o:invoke("NickChange", user, newnick)
    end
    if user.nick == o.nick then o.nick = newnick end
end

local function needNewNick(o, prefix, target, badnick)
    local newnick = o.nickGenerator(badnick)
    o:send("NICK %s", newnick)
end

-- ERR_ERRONEUSNICKNAME (Misspelt but remains for historical reasons)
handlers["432"] = needNewNick

-- ERR_NICKNAMEINUSE
handlers["433"] = needNewNick

-- NAMES list
handlers["353"] = function(o, prefix, me, chanType, channel, names)
    if o.track_users then
        o.channels[channel] = o.channels[channel] or
                                  {users = {}, type = chanType}

        local users = o.channels[channel].users
        for nick in names:gmatch("(%S+)") do
            local access, name = parseNick(nick)
            users[name] = {access = access}
        end
    end
end

-- end of NAMES
handlers["366"] = function(o, prefix, me, channel, msg)
    if o.track_users then o:invoke("NameList", channel, msg) end
end

-- no topic
handlers["331"] = function(o, prefix, me, channel)
    o:invoke("OnTopic", channel, nil)
end

-- new topic
handlers["TOPIC"] = function(o, prefix, channel, topic)
    o:invoke("OnTopic", channel, topic)
end

handlers["332"] = function(o, prefix, me, channel, topic)
    o:invoke("OnTopic", channel, topic)
end

-- topic creation info
handlers["333"] = function(o, prefix, me, channel, nick, time)
    o:invoke("OnTopicInfo", channel, nick, tonumber(time))
end

handlers["KICK"] = function(o, prefix, channel, kicked, reason)
    o:invoke("OnKick", channel, kicked, parsePrefix(prefix), reason)
end

-- RPL_UMODEIS
-- To answer a query about a client's own mode, RPL_UMODEIS is sent back
handlers["221"] =
    function(o, prefix, user, modes) o:invoke("OnUserMode", modes) end

-- RPL_CHANNELMODEIS
-- The result from common irc servers differs from that defined by the rfc
handlers["324"] = function(o, prefix, user, channel, modes)
	print('324 id : '..tostring(user.name))
    o:invoke("OnChannelMode", channel, modes)
end

handlers["MODE"] = function(o, prefix, target, modes, ...) 
	-- print(tostring(vova)..' <<><vova')
    if o.track_users and target ~= o.nick then
		print('target' .. target)
        local add = true
        local optList = {...}
		name_user = optList[1]
        print(tostring(modes)..' '..tostring(name_user)..' '..tostring(o.nick))
        if modes == '+v' or modes == '-v' then
            if o.channels[target].users[user] == nil then
                print('nil '..target)
                -- o.channels[target] = {users = {name_user}}
                o.channels[target].users[name_user] = name_user
                o.channels[target].users[name_user] = {access = {voice = {false}}}
                if o.channels[target].users[name_user] ~= nil then
                    o.channels[target].users[name_user].access.voice = modes == '+v' and true or false
                    print('jaba???? '..tostring(o.channels[target].users[name_user].access.voice))
                end
            else
                print('ne nil')
                o.channels[target].users[name_user].access.voice = modes == '+v' and true or false
            end
        end
    end
    o:invoke("OnModeChange", name_user, parsePrefix(prefix), target, modes, ...)
end

handlers["ERROR"] = function(o, prefix, message)
    o:invoke("OnDisconnect", message, true)
    o:shutdown()
    error(message, 3)
end

handlers["jaba"] = function(o, user, target, who)
    print('+++++ '..who..' '..tostring(target))
    if o.channels['#Freym_tech'].users[who] == nil then
        o.channels['#Freym_tech'].users[who] = who
        o.channels['#Freym_tech'].users[who] = {access = {voice = {false}}}
        if o.channels['#Freym_tech'].users[who] ~= nil then
            o.channels['#Freym_tech'].users[who].access.voice = target
        end
    else
        o.channels['#Freym_tech'].users[who].access.voice = target
    end
end

