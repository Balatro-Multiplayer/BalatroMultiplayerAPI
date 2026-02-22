local api_client = {}

function api_client.new(mqtt_client, base_url)
    local self = {
        mqtt = mqtt_client,
        base_url = base_url,
        pending_callback = nil,
    }
    setmetatable(self, { __index = api_client })
    return self
end

function api_client:authenticate_steam(ticket, username, callback)
    if not self.mqtt or not self.mqtt.tx_channel then
        callback("MQTT thread not running", nil)
        return
    end

    self.pending_callback = callback

    self.mqtt.on_http_response = function(status, body)
        self.mqtt.on_http_response = nil
        self.mqtt.on_http_error = nil
        local cb = self.pending_callback
        self.pending_callback = nil
        if not cb then return end

        if status ~= 200 then
            cb("Server returned status " .. tostring(status) .. ": " .. body, nil)
            return
        end

        local ok, data = pcall(function()
            if json and json.decode then
                return json.decode(body)
            end
            local j = require("json")
            return j.decode(body)
        end)

        if not ok or not data then
            cb("Failed to parse server response", nil)
            return
        end

        if not data.token then
            cb(data.error or "Server response missing token", nil)
            return
        end

        cb(nil, data)
    end

    self.mqtt.on_http_error = function(msg)
        self.mqtt.on_http_response = nil
        self.mqtt.on_http_error = nil
        local cb = self.pending_callback
        self.pending_callback = nil
        if cb then
            cb("HTTP request failed: " .. tostring(msg), nil)
        end
    end

    local body
    if json and json.encode then
        body = json.encode({ ticket = ticket, username = username })
    else
        local j = require("json")
        body = j.encode({ ticket = ticket, username = username })
    end

    self.mqtt:http_post(self.base_url .. "/api/auth/steam", body)
end

return api_client
