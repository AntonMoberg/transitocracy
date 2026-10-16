# Transitocracy prototype

Run the Godot project and use the **Roads / Trips** selector above the hourly chart.

The full neighborhood and road map stays visible while you inspect the state, regions, counties, cities, and neighborhoods. Colored boundaries and labels mark regions, counties, and cities. Click an area label or boundary, or select a name in the right inspector, to see its finances, policies, and children without changing the map. Click a neighborhood node to inspect its statistics. The breadcrumb above the inspector returns to a parent area. Tax and fee controls appear only for the selected area; directional toll controls appear when a road is selected.

## Road tools

- **Inspect:** click a road for its directional vehicle demand, queue, capacity, travel time and upkeep. Click a neighborhood gateway for its statistics.
- **Arterial:** click a start node, optional empty map points to shape the route, then an end node. Review the cost and opening date, then press **Build**.
- **Highway:** draw the same way, using active interchanges at both ends.
- **Junction:** click empty map to add a road node, or click an arterial to split it and connect future roads there.
- **Interchange:** click a node or a highway segment, then press **Build**. Highway exits become usable when construction finishes.
- **Widen:** click an open road, then press **Build** to add one lane in each direction. Existing lanes remain open during construction.
- **Demolish:** click an open road, review the resulting number of disconnected neighborhood groups, then press **Demolish**. Removal is immediate, has no refund, and ends that road's upkeep. Roads with construction underway must finish first.

Right click or press Escape to clear a road preview. Drag to pan and scroll to zoom. The **Trips** view retains the work, commercial and social flow arrows. Space pauses; keys 1–5 set simulation speed.

Construction is paid by the road's owning state, county, city, or neighborhood budget. A city funds a junction interchange; road tolls and upkeep belong to the road owner. Construction takes roughly one tenth of the original project duration, rounded up to full days: a short arterial takes at least 2 days, a highway at least 5 days, and an interchange or highway exit takes 5 days. Each road direction uses the right-hand side and has its own group of lines, one per lane. Color shows served flow versus capacity or a remaining queue; arrows show travel direction. Dashed lines are construction projects.

The clock runs continuously. The day's work, commercial, and social trip demand is prepared as hourly origin-destination matrices. Road traffic advances in 15-minute bins ahead of the clock on a background worker: vehicles use directional links, travel to downstream links, queue at capacity, and carry into the next day. Independent road route searches, departure templates, and hourly demand calculations use Godot's worker pool across CPU cores. The traffic worker keeps a private region snapshot and prepares its next mutable state before handing the result to the UI. Compact 15-minute checkpoints support policy and road changes without copying every in-flight cohort. At midnight, income and property taxes, sales and fee revenue, road upkeep, construction, and neighborhood migration update separate jurisdiction budgets. The clock waits at the boundary while a new day is prepared, and the UI continues rendering.

The map generates one state, four regions, eight counties, 16 cities, and 96 neighborhoods. All jurisdiction selections show the same detailed neighborhood network and road flows. The map starts with a sparse connected tree of arterial roads and no highways. Road crossings connect only at explicit junctions or interchanges. If demolition separates neighborhoods, vehicles already en route are rerouted or stranded, and new trips between disconnected groups stop. Detailed terrain, local streets, and transit services are later layers.

## Verification

The `tests/` directory contains headless smoke checks for generation, trip flow, migration, UI, road construction, traffic, road controls, and parallel simulation consistency.
