extends SceneTree

const Network = preload("res://scripts/simulation/road_network_generator.gd")
const Graph = preload("res://scripts/simulation/road_graph.gd")
const Route = preload("res://scripts/simulation/road_route_builder.gd")
const Topology = preload("res://scripts/simulation/road_topology.gd")
var errors: Array[String] = []
const Setup = preload("res://scripts/simulation/region_setup.gd")

func _initialize() -> void:
	var seeds := [1729, 3819, 7601356]
	var sizes := [256, 768]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("seed="): seeds = [int(arg.substr(5))]
		if arg.begins_with("cities="): sizes = [int(arg.substr(7))]
	for cities in sizes:
		for seed_value in seeds:
			var started := Time.get_ticks_msec()
			var region = Setup.build(seed_value, cities, 0.10).region
			_check(region.validation_errors().is_empty(),"region validation failed: %s" % region.validation_errors())
			var totals := {}
			var topology:=Topology.audit(region,true)
			print("TOPOLOGY_AUDIT ",topology)
			for id in topology.attachments:
				for link in region.road_links:
					if link.id!=id: continue
					print("Attachment ",id," endpoints ",link.points[0].distance_to(region.road_nodes[link.from_node_id].position_km),"/",link.points[-1].distance_to(region.road_nodes[link.to_node_id].position_km))
					for junction in link.junctions:
						var gap:float=Topology.sample(link.points,junction.station_km).point.distance_to(region.road_nodes[junction.node_id].position_km)
						if gap>Topology.EPS: print(" interior ",junction," gap ",gap)
			for id in topology.dead_ends: print("Dead end ",id," ",Topology.node_approaches(region,id).map(func(a):return [a.link.id,a.link.road_class,a.link.length_km]))
			_check(topology.dead_ends.is_empty(),"generated rural dead ends")
			_check(topology.kinks.is_empty(),"discontinuous two-arm joins")
			_check(topology.attachments.is_empty(),"road geometry detached from nodes")
			for link in region.road_links:
				var key: String = link.road_class
				if not totals.has(key): totals[key] = {"count": 0, "km": 0.0}
				totals[key].count += 1
				totals[key].km += link.length_km
			var components := Network._road_components(Graph.adjacency(region))
			var component := -1
			for city_id in region.starting_city_ids:
				var hub: int = region.city_hub_node_ids[city_id]
				if component < 0: component = components[hub]
				_check(component == components[hub], "disconnected starting city %d, seed %d/%d" % [city_id,seed_value,cities])
				var access: int = region.city_highway_access_node_ids[city_id]
				_check(access >= 0 and components[access] == component,"missing reachable highway access, seed %d/%d" % [seed_value,cities])
			for link in region.road_links:
				if link.road_class != "Highway": continue
				_check(components[link.from_node_id] == component,"disconnected highway component")
				_check(link.trunk_route_id >= 0 and link.map_major,"missing trunk identity or overview importance")
				_check(Route.significant_curve_radius(link.points) >= 1.99,"highway curvature below minimum")
				var tunnel_km := 0.0
				for span in link.terrain_spans:
					if span.kind == "Tunnel":
						tunnel_km += span.length_km
						_check(span.length_km <= 3.05,"tunnel exceeds exceptional length")
				_check(tunnel_km <= link.length_km * .05,"too much of highway in tunnels")
				for i in range(1,link.points.size()):
					var grade: float = absf(link.elevation_profile_m[i]-link.elevation_profile_m[i-1])/maxf(.001,link.points[i].distance_to(link.points[i-1])*1000.0)
					_check(grade <= .0601,"highway grade exceeds six percent")
			print("NETWORK_METRICS ", JSON.stringify({"seed":seed_value,"cities":cities,"ms":Time.get_ticks_msec()-started,"roads":totals}))
	print("Network invariants: ", "PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	if not ok and not errors.has(message): errors.append(message)
