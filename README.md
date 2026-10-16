# Transitocracy prototype

Run the Godot project and use the **Roads / Trips** selector above the hourly chart.

## Road tools

- **Inspect:** click a road for its directional vehicle volume, capacity, travel time and upkeep. Click a neighborhood gateway for its statistics.
- **Arterial:** click a start node, optional empty map points to shape the route, then an end node. Review the cost and opening date, then press **Build**.
- **Highway:** draw the same way, using active interchanges at both ends.
- **Junction:** click empty map to add a road node, or click an arterial to split it and connect future roads there.
- **Interchange:** click a node or a highway segment, then press **Build**. Highway exits become usable when construction finishes.
- **Widen:** click an open road, then press **Build** to add one lane in each direction. Existing lanes remain open during construction.
- **Demolish:** click an open road, review the resulting number of disconnected neighborhood groups, then press **Demolish**. Removal is immediate, has no refund, and ends that road's upkeep. Roads with construction underway must finish first.

Right click or press Escape to clear a road preview. Drag to pan and scroll to zoom. The **Trips** view retains the work, commercial and social flow arrows. Space pauses; keys 1–5 set simulation speed.

Road construction is paid from the regional treasury when funded. Construction takes roughly one tenth of the original project duration, rounded up to full days: a short arterial takes at least 2 days, a highway at least 5 days, and an interchange or highway exit takes 5 days. Each midnight, income tax is credited, upkeep is charged, completed projects open, neighborhood migration advances, and hourly trip demand and road traffic are rebuilt. Each road direction uses the right-hand side and has its own group of lines, one per lane. Each group's color shows its own traffic as a share of directional capacity; arrows show travel direction. Dashed lines are construction projects. Minute values interpolate between hourly results.

The map starts with the shortest connected tree of arterial roads; there are no starting highways. Road crossings connect only at explicit junctions or interchanges. If demolition separates neighborhoods, trips between those groups stop until a new road connects them. Detailed terrain, local streets, and transit services are later layers.

## Verification

The `tests/` directory contains headless smoke checks for generation, trip flow, migration, UI, road construction, traffic, and road controls.
