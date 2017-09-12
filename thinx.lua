-- THiNX Example device application
-- Customize your firmware at nodemcu-build.com
-- THiNX requires following modules: http,mqtt,net,cjson,wifi
-- Minimum hardware: ESP-01 512kB (2mb)

_G.cjson = sjson

dofile("config.lua") -- must contain 'ssid', 'password' because this firmware does not currently support captive portal

print ("* THiNX:Client v" .. THINX_FIRMWARE_VERSION_SHORT) -- compatible with API 0.9.29

mqtt_client = nil
mqtt_connected = false
available_update_url = nil

thx_connected_response = "{ \"status\" : \"connected\" }"
thx_disconnected_response = "{ \"status\" : \"disconnected\" }"
thx_reboot_response = "{ \"status\" : \"rebooting\" }"
thx_update_question = "{ title: \"Update Available\", body: \"There is an update available for this device. Do you want to install it now?\", type: \"actionable\", response_type: \"bool\" }"
thx_update_success = "{ title: \"Update Successful\", body: \"The device has been successfully updated.\", type: \"success\" }"

function registration_json_body()
  return '{"registration": {"mac": "'..thinx_device_mac()..'", "firmware": "'..THINX_FIRMWARE_VERSION..'", "commit": "' .. THINX_COMMIT_ID .. '", "version": "'..THINX_FIRMWARE_VERSION_SHORT..'", "checksum": "' .. THINX_COMMIT_ID .. '", "alias": "' .. THINX_ALIAS .. '", "udid" :"' ..THINX_UDID..'", "owner" : "'..THINX_OWNER..'", "platform" : "nodemcu" }}'
end

function thinx_device_mac()
  return wifi.sta.getmac()
end

function mqtt_device_channel()
  return "/"..THINX_OWNER.."/".. THINX_UDID
end

function mqtt_status_channel()
  return mqtt_device_channel() .. "/status"
end

-- CONNECTION

KEEPALIVE = 120
CLEANSESSION = false
MQTT_LWT_QOS = 0
MQTT_LWT_RETAIN = 1
MQTT_QOS = 0
MQTT_RETAIN = 1
MQTT_DEVICE_QOS = 2

function connect(THINX_ENV_SSID, THINX_ENV_PASS)
  wifi.setmode(wifi.STATION)
  wifi.sta.config{ssid=THINX_ENV_SSID, pwd=THINX_ENV_PASS}
  wifi.sta.connect()
  tmr.alarm(1, 5000, 1, function()
    if wifi.sta.getip() == nil then
      print("* THiNX: Connecting " .. THINX_ENV_SSID .. "...")
    else
      tmr.stop(1)
      print("* THiNX: Connected to " .. THINX_ENV_SSID .. ", IP is "..wifi.sta.getip())
      thinx_register()
    end
  end)
end

-- devuce registration request
function thinx_register()
  restore_device_info()
  url = 'http://' .. THINX_CLOUD_URL .. ':7442/device/register'
  headers = 'Authentication:' .. THINX_API_KEY .. '\r\n' ..
            'Accept: application/json\r\n' ..
            'Origin: device\r\n' ..
            'Content-Type: application/json\r\n' ..
            'User-Agent: THiNX-Client\r\n'
  data = registration_json_body()
  http.post(url, headers, data,
    function(code, rdata)
      if (code < 0) then
        print("* THiNX: HTTP request failed")
      else
        if code == 200 then
          parse(rdata)
      end
    end
  end)
end

-- firmware update request
function thinx_update(update_url)

  if update_url ~= null then
    url = update_url
  else
    url = 'http://' .. THINX_CLOUD_URL .. ':7442/device/firmware'
  end

  headers = 'Authentication: ' .. THINX_API_KEY .. '\r\n' ..
            'Accept: */*\r\n' ..
            'Origin: device\r\n' ..
            'Content-Type: application/json\r\n' ..
            'User-Agent: THiNX-Client\r\n'

  data = registration_json_body()
  print("* THiNX: Update Request: " .. data)
  http.post(url, headers, body,
    function(code, data)
      if (code < 0) then
        print("* THiNX: HTTP request failed")
      else
        if code == 200 then
          update_and_reboot(data)
      end
    end
  end)
end

-- RESPONSE PARSER

function parse(response_json)
  local ok, response = pcall(cjson.decode, response_json)
  if ok then
    print("parse_update")
    parse_update(response)
    print("parse_registration")
    parse_registration(response)
    print("parse_notification")
    parse_notification(response)
  end

  if THINX_UDID ~= "" then
    thinx_mqtt()
  end
end

-- DEVICE INFO

function get_device_info()
  device_info = {}
  if THINX_ALIAS ~= "" then
    device_info['alias'] = THINX_ALIAS
  end
  if THINX_OWNER ~= "" then
    device_info['owner'] = THINX_OWNER
  end
  if THINX_API_KEY~= "" then
    device_info['apikey'] = THINX_API_KEY
  end
  if THINX_UDID ~= "" then
    device_info['udid'] = THINX_UDID
  end
  if THINX_AUTO_UPDATE ~= "" then
    device_info['auto_update'] = THINX_AUTO_UPDATE
  end
  if THINX_UDID ~= "" then
    device_info['udid'] = THINX_UDID
  end
  if available_update_url ~= nil then
    device_info['available_update_url'] = available_update_url
  end
  device_info['platform'] = "nodemcu"
  return device_info
end

function apply_device_info(info)
    if info['alias'] ~= nil then
        THINX_ALIAS = info['alias']
    end
    if info['owner'] ~= nil then
        if info['owner'] ~= "" then
            THINX_OWNER = info['owner']
        end
    end
    if info['apikey'] ~= nil then
        THINX_API_KEY = info['apikey']
    end
    if info['auto_update'] ~= nil then
        THINX_AUTO_UPDATE = info['auto_update']
    end
    if info['udid'] ~= nil then
        THINX_UDID = info['udid']
    end
    if info['available_update_url'] ~= nil then
        available_update_url = info['available_update_url']
    end
end

-- Used by response parser
function save_device_info()
  if file.open("thinx.cfg", "w") then
    info = cjson.encode(get_device_info())
    file.write(info .. '\n')
    file.close()
  end
end

-- Restores incoming data from filesystem overriding build-time-constants
function restore_device_info()
  if file.open("thinx.cfg", "r") then
    data = file.read('\n')
    file.close()
    local ok, info = pcall(cjson.decode, data)
    if ok then
        apply_device_info(info)
    end
  end
end

-- MQTT

function thinx_mqtt()

  restore_device_info()

  if THINX_API_KEY == nil then
      return;
  end

  mqtt_client = mqtt.Client(node.chipid(), KEEPALIVE, THINX_UDID, THINX_API_KEY, 0)
  mqtt_client:lwt(mqtt_status_channel(), thx_disconnected_response, MQTT_LWT_QOS, MQTT_LWT_RETAIN)

  mqtt_client:on("connect", function(client)
      mqtt_connected = true
      client:subscribe(mqtt_device_channel(), MQTT_DEVICE_QOS, function(client) print("* THiNX: Subscribed to device channel (1).") end)
      client:publish(mqtt_status_channel(), registration_json_body(), MQTT_QOS, 0)
      client:publish(mqtt_status_channel(), thx_connected_response, MQTT_QOS, MQTT_RETAIN)
    end)

  mqtt_client:on("offline", function(client)
      mqtt_connected = false
    end)

  mqtt_client:on("message", function(client, topic, data)
    if data ~= nil then
      process_mqtt(data)
    end
  end)

  if mqtt_connected == false then
    mqtt_client:connect(THINX_MQTT_URL, THINX_MQTT_PORT, KEEPALIVE, THINX_UDID, THINX_API_KEY,
      function(client)
        mqtt_connected = true
        client:subscribe(mqtt_device_channel(), MQTT_DEVICE_QOS, function(client) print("* THiNX: Subscribed to device channel (2).") end)
        client:publish(mqtt_status_channel(), thx_connected_response, MQTT_QOS, MQTT_RETAIN)
        client:publish(mqtt_status_channel(), registration_json_body(), MQTT_QOS, MQTT_RETAIN)
      end,
      function(client, reason)
        mqtt_connected = false
      end)
  end
end

function process_mqtt(payload_json)
  local ok, payload = pcall(cjson.decode, payload_json)
  if ok then
    local upd = payload['update']
    if upd ~= nil then
      print("* THiNX: Update payload: " ..cjson.encode(upd))
      update_and_reboot(payload)
    end
    local msg = payload['message']
    if msg ~= nil then
      print("* THiNX: Incoming MQTT message: " .. msg)
      parse(msg)
    end
  end
end

function parse_notification(json)
  local no = json.notification
  if no then
    print("Parsing notification...")
    local type = no.response_type

    if type == "bool" or type == "boolean" then
      local response = no.response
      if response == true then
        thinx_update(available_update_url) -- should fetch OTT without url
      end
    end

    if type == "string" or type == "String" then
      local response = no['response']
      if response == "yes" then
        thinx_update(available_update_url) -- should fetch OTT without url
      end
    end
  else
    print("Not a notification")
  end
end

function parse_registration(json)
  local reg = json.registration
  if reg ~= nil then
    print("*TH: Registration: ")
    local status = reg.status
    if status == "OK" then
      if reg['apikey'] ~= nil then
        THINX_API_KEY = reg['apikey']
        print("*TH: API Key: "..THINX_API_KEY)
      end
      if reg['alias'] ~= nil then
        THINX_ALIAS = reg['alias']
        print("*TH: Alias: "..THINX_ALIAS)
      end
      if reg['owner'] ~= nil then
        THINX_OWNER = reg['owner']
        print("*TH: Owner: "..THINX_OWNER)
      end
      if reg['udid'] ~= nil then
        THINX_UDID = reg['udid']
        print("*TH: UDID: "..THINX_UDID)
      end
      save_device_info()
      local commit = reg['commit']
      local version = reg['version']
      if commit == THINX_COMMIT_ID and version == THINX_FIRMWARE_VERSION_SHORT then
        if available_update_url ~= nil then
          available_update_url = nil
          save_device_info()
          notify_on_successful_update()
        end
      end
      print("*TH: Saving checking data.")
      save_device_info()
      return
    else
      print("*TH: Registration failed, no success.")
    end

    if status == "FIRMWARE_UPDATE" then
      local update_url = reg['url']
      if update_url ~= nil then
        print("*TH: Running update with URL:" .. update_url)
        thinx_update(update_url)
      end
      return
    end
    print("Unknown status." .. status)
    else
      print("no registration in "..json)
    return
  end
end

function parse_update(json)
  local reg = json.update
  if upd then
    print("Parsing update...")
    local mac = upd['mac']
    local commit = upd['commit']
    local version = upd['version']
    local url = upd['url']

    if commit == THINX_COMMIT_ID and version == THINX_FIRMWARE_VERSION then
      available_update_url = nil;
      save_device_info();
      notify_on_successful_update();
      return
    end

    if THINX_AUTO_UPDATE == false then
        send_update_question()
    else
        if url ~= null then
          available_update_url = url
          save_device_info()
          if available_update_url then
              thinx_update(available_update_url)
          end
          return
        end
    end
  else
    print("Not an update")
  end
end

function notify_on_successful_update()
  if mqtt_client ~= null then
    client:publish(mqtt_status_channel(), thx_update_success, MQTT_LWT_QOS, MQTT_LWT_RETAIN)
  end
end

function send_update_question()
  if mqtt_client ~= null then
    client:publish(mqtt_status_channel(), thx_update_question, MQTT_LWT_QOS, MQTT_LWT_RETAIN)
  end
end

-- UPDATES

-- update specific filename on filesystem with data, returns success/false
function update_file(name, data)
  if file.open(name, "w") then
    file.write(data)
    file.close()
    return true
  else
    return false
  end
end

-- update specific filename on filesystem with data from URL
function update_from_url(name, url)
  http.get(url, nil, function(code, data)
    if (code < 0) then
      print("* THiNX: HTTP Update request failed")
    else
      if code == 200 then
        local success = update_file(name, data)
        if success then
          client:publish(mqtt_status_channel(), thx_reboot_response, MQTT_LWT_QOS, MQTT_LWT_RETAIN)
          node.restart()
        else
          file.rename("thinx.bak", "thinx.lua")
        end
      end
    end
  end)
end

-- the update payload may contain files, URL or OTT
function update_and_reboot(payload)

  -- update variants
  local type  = payload['type'] -- defaults to file
  local files = payload['files']
  local ott   = payload['ott']
  local url   = payload['url']
  local name  = "thinx.lua"

  -- as a default for NodeMCU, files are updated instead of whole firmware
  if type ~= nil then
    type = "file"
  end

  if files then
    file.rename("thinx.lua", "thinx.bak") -- backup
    local success = false
    for file in files do
      local name = file['name']
      local data = file['data']
      local url = file['url']
      if (name and data) then
        success = update_file(name, data)
      elseif (name and url) then
        update_from_url(name, url)
        success = true -- why?
      end
    end
  end

  if ott then
    if type == "file" then
      url = 'http://' .. THINX_CLOUD_URL .. ':7442/device/firmware?ott=' .. ott
      print("* THiNX: Updating " .. name .. " from " .. url)
      update_from_url(name, url)
      success = true
    end
  end

  if url then
    if type == "file" then
      print("* THiNX: Updating " .. name .. " from URL " .. url)
      update_from_url(name, url)
      success = true
    end
  end

  if success then
    client:publish(mqtt_status_channel(), thx_reboot_response, MQTT_LWT_QOS, MQTT_LWT_RETAIN)
    node.restart()
  else
    file.rename("thinx.bak", "thinx.lua")
    print("* THiNX: Update aborted.")
  end

end

function thinx()
    restore_device_info()
    connect(THINX_ENV_SSID, THINX_ENV_PASS)
end

thinx()
