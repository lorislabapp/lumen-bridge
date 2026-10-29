import Foundation
import Testing
@testable import LumenAssistant

@Suite(.serialized) struct HomeAssistantTests {
    @Test func restClientAgainstMockServer() async throws {
        let server = try MockHAServer(token: "test-token-123")
        try await server.start()
        defer { server.stop() }
        let client = HomeAssistantClient(transport: URLSessionHATransport(baseURL: server.baseURL) { "test-token-123" })
        try await client.verify()
        let states = try await client.states()
        #expect(states.count == 5)
        let cover = try await client.state("cover.volets_salon")
        #expect(cover.deviceClass == "shutter")
        #expect(cover.currentPosition == 100)
        try await client.call(ServiceCall(domain: "light", service: "turn_on", entityID: "light.salon_plafond"))
        #expect(server.state("light.salon_plafond") == "on")
        let posts = server.requests.filter { $0.method == "POST" }
        #expect(posts.last?.path == "/api/services/light/turn_on")
        let body = try JSONSerialization.jsonObject(with: posts.last!.body) as? [String: Any]
        #expect(body?["entity_id"] as? String == "light.salon_plafond")
        #expect(server.requests.allSatisfy { $0.authorization == "Bearer test-token-123" })
        let areas = await client.areas(for: ["light.salon_plafond", "lock.porte_entree"])
        #expect(areas == ["light.salon_plafond": "Salon", "lock.porte_entree": "Entrée"])
    }

    @Test func wrongTokenIsUnauthorized() async throws {
        let server = try MockHAServer(token: "right")
        try await server.start()
        defer { server.stop() }
        let client = HomeAssistantClient(transport: URLSessionHATransport(baseURL: server.baseURL) { "wrong" })
        await #expect(throws: HomeAssistantError.unauthorized) { try await client.verify() }
    }

    @Test func refusesBadIdentifiersBeforeTheNetwork() async throws {
        let client = HomeAssistantClient(transport: URLSessionHATransport(baseURL: URL(string: "http://127.0.0.1:9")!) { "t" })
        await #expect(throws: HomeAssistantError.notConfigured) {
            try await client.call(ServiceCall(domain: "light", service: "turn_on", entityID: "light.x/../../api/config"))
        }
        await #expect(throws: HomeAssistantError.notConfigured) {
            try await client.call(ServiceCall(domain: "light", service: "turn_on", entityID: "light.ok", data: ["entity_id": 1]))
        }
    }

    @Test func bearerNeverOverPublicCleartext() {
        #expect(URLSessionHATransport.permitsBearer(URL(string: "https://ha.example.com")!))
        #expect(URLSessionHATransport.permitsBearer(URL(string: "http://192.168.1.10:8123")!))
        #expect(URLSessionHATransport.permitsBearer(URL(string: "http://10.9.8.5:8123")!))
        #expect(URLSessionHATransport.permitsBearer(URL(string: "http://homeassistant.local:8123")!))
        #expect(URLSessionHATransport.permitsBearer(URL(string: "http://100.101.1.2:8123")!))
        #expect(!URLSessionHATransport.permitsBearer(URL(string: "http://ha.example.com")!))
        #expect(!URLSessionHATransport.permitsBearer(URL(string: "http://8.8.8.8:8123")!))
        #expect(URLSessionHATransport.normalizedBase("http://ha.local:8123/") != nil)
        #expect(URLSessionHATransport.normalizedBase("http://user:pw@ha.local") == nil)
        #expect(URLSessionHATransport.normalizedBase("ftp://ha.local") == nil)
    }

    @Test func serviceMappingAndUndo() {
        let reg = Fixture.registry
        let shutter = reg.device(id: "cover.volets_salon")!
        let close = ActionPlan(action: .close, targets: [shutter])
        #expect(ServiceMapper.calls(for: close, states: [:]) == [ServiceCall(domain: "cover", service: "close_cover", entityID: shutter.entityID)])
        let before = ["cover.volets_salon": HAEntity(entityID: "cover.volets_salon", state: "open", currentPosition: 60)]
        #expect(ServiceMapper.inverse(of: close, before: before)
                == [ServiceCall(domain: "cover", service: "set_cover_position", entityID: shutter.entityID, data: ["position": 60])])
        let heat = ActionPlan(action: .raise, targets: [reg.device(id: "climate.salon")!])
        let st = ["climate.salon": HAEntity(entityID: "climate.salon", state: "heat", temperature: 20)]
        #expect(ServiceMapper.calls(for: heat, states: st).first?.data["temperature"] == 21)
        #expect(ServiceMapper.inverse(of: heat, before: st)?.first?.data["temperature"] == 20)
        // T2 never gets an automatic undo.
        let unlock = ActionPlan(action: .unlock, targets: [reg.device(id: "lock.porte_entree")!])
        #expect(ServiceMapper.inverse(of: unlock, before: [:]) == nil)
        let light = ActionPlan(action: .turnOn, targets: [reg.device(id: "light.cuisine")!])
        #expect(ServiceMapper.inverse(of: light, before: ["light.cuisine": HAEntity(entityID: "light.cuisine", state: "off")])
                == [ServiceCall(domain: "light", service: "turn_off", entityID: "light.cuisine")])
    }

    @Test func registrySyncKeepsOwnerChoices() async throws {
        let server = try MockHAServer(token: "t")
        try await server.start()
        defer { server.stop() }
        let client = HomeAssistantClient(transport: URLSessionHATransport(baseURL: server.baseURL) { "t" })
        let entities = try await client.states()
        let areas = await client.areas(for: entities.map(\.entityID))
        var reg = RegistrySync.merge(entities, areas: areas, into: DeviceRegistry())
        #expect(reg.devices.allSatisfy { !$0.exposed })          // nothing exposed by default
        #expect(reg.device(id: "sensor.temp") == nil)              // sensors are not controllable
        #expect(reg.device(id: "cover.volets_salon")?.kind == .shutter)
        #expect(reg.device(id: "media_player.tv_salon")?.kind == .tv)
        #expect(reg.device(id: "lock.porte_entree")?.room == "Entrée")
        #expect(Set(reg.rooms.map(\.name)) == ["Salon", "Entrée"])
        // Owner exposes one device and renames its room; resync keeps it.
        let i = reg.devices.firstIndex { $0.entityID == "light.salon_plafond" }!
        reg.devices[i].exposed = true
        reg.devices[i].aliases = ["plafonnier"]
        let again = RegistrySync.merge(entities, areas: areas, into: reg)
        #expect(again.device(id: "light.salon_plafond")?.exposed == true)
        #expect(again.device(id: "light.salon_plafond")?.aliases == ["plafonnier"])
    }
}
