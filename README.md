# Transitocracy prototype

Run the Godot project and use the **Roads / Trips** selector above the chart. The **Map size** control generates 96, 5,120, or 20,480 neighborhoods; the 5,120-neighborhood state is the default. Generation runs on a worker so the interface remains responsive.

The full neighborhood and road map stays visible while you inspect the state, regions, counties, cities, and neighborhoods. Colored boundaries and labels mark regions, counties, and cities. Click an area label or boundary, or select a name in the right inspector, to see its finances, policies, and children without changing the map. Click a neighborhood node to inspect its statistics. The breadcrumb above the inspector returns to a parent area. Tax and fee controls appear only for the selected area; directional toll controls appear when a road is selected.

## Road tools

- **Inspect:** click a road for its directional vehicle demand, queue, capacity, travel time and upkeep. Click a neighborhood gateway for its statistics.
- **Arterial:** click a start node, optional empty map points to shape the route, then an end node. Review the cost and opening date, then press **Build**.
- **Highway:** draw the same way, using active interchanges at both ends.
- **Junction:** click empty map to add a road node, or click an arterial to split it and connect future roads there.
- **Interchange:** click a node or a highway segment, then press **Build**. Highway exits become usable when construction finishes.
- **Widen:** click an open road, then press **Build** to add one lane in each direction. Existing lanes remain open during construction.
- **Demolish:** click an open road, review the resulting number of disconnected neighborhood groups, then press **Demolish**. Removal is immediate, has no refund, and ends that road's upkeep. Roads with construction underway must finish first.

Right click or press Escape to clear a road preview. Drag to pan and scroll to zoom. The **Trips** view retains the work, commercial and social flow arrows. Space pauses; keys **1–4** choose Second, Minute, Hour, or Day simulation. **Q/W/E** choose Normal, Faster (2×), or Fastest (4×) pace. The clock caps its actual rate when calculations fall behind and shows the measured rate beside the controls.

Construction is paid by the road's owning state, county, city, or neighborhood budget. A city funds a junction interchange; road tolls and upkeep belong to the road owner. Construction takes roughly one tenth of the original project duration, rounded up to full days: a short arterial takes at least 2 days, a highway at least 5 days, and an interchange or highway exit takes 5 days. Each road direction uses the right-hand side and has its own group of lines, one per lane. Color shows served flow versus capacity or a remaining queue; arrows show travel direction. Dashed lines are construction projects.

## Simulation modes

| Mode | Base game time per real second | Traffic calculation | Available while inspecting |
| --- | ---: | --- | --- |
| Second | 1 second | Directional road flow and queues updated each second | Every level |
| Minute | 1 minute | Directional roads advanced in short batches | Every level |
| Hour | 1 hour | City-to-city demand assigned to road corridors | State or region |
| Day | 1 day | Daily average region-to-region demand assigned to road corridors | State or region |

Every mode uses the same calendar, directional queue totals, daily trip profiles, and neighborhood economy. Work, shopping, and social trips follow the existing hourly departure distributions. The fast modes estimate traffic on the existing road network: highways and arterials crossing city boundaries retain directional congestion colors, while neighborhood links and nodes are subdued. Planned major roads keep their actual construction geometry. Selecting a county, city, or neighborhood during Hour or Day mode returns to Minute mode at the same timestamp and reconstructs plausible local queues from the aggregate total. The simulation preserves population and jurisdiction finances during mode changes.

Road flow is aggregate vehicle counts rather than individual agents. Each direction exposes arrival rate, served rate, queue size, and speed so a later renderer can place cosmetic cars along the right-hand lanes. The clock advances only through completed calculations. Day mode prepares seven upcoming days as one continuous background cycle and keeps a bounded buffer of daily results, so the calendar can pass midnight without a separate calculation pause each day. Its timeline shows seven calendar days with daily work, commercial, social, or combined trip totals; dim points are estimates until the background calculation prepares those days. Click a day to see its total. Other modes keep the 24-hour timeline. Road openings, taxes, and neighborhood migration still take effect on their scheduled dates. Changing a policy or road discards prepared future days and starts a fresh cycle. The fastest pace is a target; playback follows the measured preparation rate when CPU time is limited.

The small map generates one state, four regions, eight counties, 16 cities, and 96 neighborhoods. The default map generates 16 regions, 64 counties, 128 cities, and 5,120 neighborhoods. The stretch map has 512 cities and 20,480 neighborhoods. Each map starts with a sparse connected tree of arterial roads and no highways. Road crossings connect only at explicit junctions or interchanges. Detailed terrain, local streets, transit services, and rendered cars are later layers.

Large maps use compact city and region origin–destination demand. Work trips balance workers and jobs over each city's 64 nearest reachable cities; shopping and social trips use the same candidate set with gravity weights. The hourly Gaussian departure curves still drive Second, Minute, and Hour modes. Day mode uses one daily average road assignment on the existing links, retaining directional congestion estimates and fiscal totals. Map rendering caps visible neighborhood detail and hides local roads at broad state scale. A severed neighborhood gateway loses road access and external trips. A worker prepares the next seven days and copies state snapshots outside the UI thread; large-map road edits also recalculate on a worker.

## Verification

The `tests/` directory contains headless smoke checks for generation, trip flow, migration, UI, road construction, traffic, road controls, multiscale modes, day handoffs, and parallel simulation consistency. Run `tests/large_scale_benchmark.gd` headlessly to measure the default state, or pass `-- --cities=512` to measure the stretch state. Run `tests/large_ui_smoke.gd` to check the seven-day buffer and UI frame time. `tests/multiscale_benchmark.gd` measures two seven-day cycles on the original 96-neighborhood map.
