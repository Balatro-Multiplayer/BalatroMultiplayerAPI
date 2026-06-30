-- Transport contract: the capability surface that lobby/action/matchmaking
-- business logic depends on, instead of importing the concrete MQTT client.
--
-- Lua has no interfaces, so this is a documentation contract: the composition
-- root (core.lua + api/connection.lua) constructs the concrete
-- networking.mqtt_client and the business layer reaches it only through
-- MPAPI.get_mqtt(), which is guaranteed to return a value satisfying the shape
-- below (or nil when offline).
--
--   transport:lobby_topic(code, suffix) -> string
--   transport:subscribe(topic, qos, handler)   -- handler(topic, payload)
--   transport:unsubscribe(topic)
--   transport:publish(topic, payload, qos, retain)
--   transport:start_thread()
--   transport:update()
--   transport:disconnect()
--
-- Any object passed where a transport is expected must implement these methods.
-- This file intentionally defines no implementation; it exists to name the
-- contract and give a single place to document it.
MPAPI.contracts = MPAPI.contracts or {}
MPAPI.contracts.transport = {
	methods = { 'lobby_topic', 'subscribe', 'unsubscribe', 'publish', 'start_thread', 'update', 'disconnect' },
}
