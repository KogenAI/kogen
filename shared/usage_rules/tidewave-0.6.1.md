# tidewave

Tidewave is an Elixir library for managing tidal data and calculations. It provides tools for working with tidal predictions, harmonic constituents, and water level information for coastal applications.

## Quick Start

### Installation

Add tidewave to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:tidewave, "~> 0.6.1"}
  ]
end
```

Run `mix deps.get` to fetch the dependency.

### Basic Usage

```elixir
# Calculate tidal predictions for a location
Tidewave.predict(location: "Boston Harbor", date: ~D[2026-06-22])

# Get high/low tide times
Tidewave.extrema(location: "Boston Harbor", date: ~D[2026-06-22])

# Calculate water level at a specific time
Tidewave.water_level(
  location: "Boston Harbor",
  datetime: ~N[2026-06-22 12:00:00]
)
```

## Core Concepts

### Tidal Stations

Tidewave works with predefined tidal stations indexed by name or station ID. Stations contain harmonic constituent data used for predictions.

```elixir
# List available stations
Tidewave.stations()

# Get station metadata
Tidewave.station_info("Boston Harbor")
```

### Harmonic Constituents

Tidal predictions are calculated using harmonic constituents (amplitude and phase lag). Each station has constituent data for:

- M2 (principal lunar semi-diurnal)
- S2 (principal solar semi-diurnal)
- N2, K1, O1, and others

The library handles constituent calculations internally.

### Predictions

Water level predictions are computed as the sum of harmonic constituents adjusted for the date and time of interest.

```elixir
# Single prediction
{:ok, level} = Tidewave.predict(
  station: "Boston Harbor",
  datetime: ~N[2026-06-22 14:30:00]
)

# Range of predictions
Tidewave.predict_range(
  station: "Boston Harbor",
  start: ~N[2026-06-22 00:00:00],
  end: ~N[2026-06-22 23:59:59],
  interval: :hourly
)
```

### Extrema (High/Low Tides)

Calculate high and low tide times for a given day or date range:

```elixir
# Daily extrema
{:ok, extrema} = Tidewave.extrema(
  station: "Boston Harbor",
  date: ~D[2026-06-22]
)

# Returns list of %{type: :high | :low, time: datetime, height: float}
```

## Configuration

### Station Selection

Specify stations by common name or NOAA station ID:

```elixir
# By name
Tidewave.predict(station: "Boston Harbor", datetime: datetime)

# By NOAA ID
Tidewave.predict(station: 8443970, datetime: datetime)
```

### Time Zone Handling

Tidewave uses UTC internally. Convert local times as needed:

```elixir
# Convert to UTC before prediction
local = DateTime.new!(~D[2026-06-22], ~T[14:30:00], "America/New_York")
utc = DateTime.shift_zone!(local, "UTC")
Tidewave.predict(station: "Boston Harbor", datetime: utc)
```

### Prediction Units

Water levels are returned in meters (SI units) by default. Some stations may use feet; check station metadata.

```elixir
{:ok, info} = Tidewave.station_info("Boston Harbor")
# info.unit will be :meters or :feet
```

## Best Practices

### Handle Errors

Predictions may fail for invalid stations or out-of-range dates. Always pattern match on `{:ok, result}` and `{:error, reason}`:

```elixir
case Tidewave.predict(station: station, datetime: datetime) do
  {:ok, level} ->
    IO.puts("Water level: #{level} meters")
  {:error, :unknown_station} ->
    IO.puts("Station not found")
  {:error, :out_of_range} ->
    IO.puts("Prediction date out of harmonic data range")
end
```

### Cache Station Data

Station metadata and constituent data are relatively static. Cache station info to avoid repeated lookups:

```elixir
# Cache at application start or in a module
@stations Tidewave.stations() |> Enum.map(&{&1.id, &1}) |> Map.new()

def get_station(id) do
  Map.get(@stations, id)
end
```

### Batch Predictions

For multiple predictions, use range functions more efficiently than individual calls:

```elixir
# Good: single range call
Tidewave.predict_range(
  station: station,
  start: start_time,
  end: end_time,
  interval: :hourly
)

# Avoid: multiple individual calls in a loop
for hour <- 0..23 do
  datetime = start_time |> DateTime.add(hour * 3600)
  Tidewave.predict(station: station, datetime: datetime)
end
```

### Validate Station Names

Always check that requested stations exist before building predictions into queries:

```elixir
available = Tidewave.stations() |> Enum.map(& &1.name)

if Enum.member?(available, requested_station) do
  Tidewave.predict(station: requested_station, datetime: datetime)
else
  {:error, "Station not available"}
end
```

### Account for Datum

Understand the vertical datum used by your station (e.g., Mean Sea Level, Mean Lower Low Water). Heights are relative to the station's specific datum; adjust if comparing across stations.

```elixir
{:ok, info} = Tidewave.station_info("Boston Harbor")
# info.datum tells you the reference level
```

## Common Patterns

### Daily Tidal Report

```elixir
defmodule TidalReport do
  def daily_summary(station, date) do
    {:ok, extrema} = Tidewave.extrema(station: station, date: date)

    extrema
    |> Enum.map(fn tide ->
      {tide.type, tide.time, tide.height}
    end)
  end
end
```

### Slack Water Detection

Tidewave doesn't provide slack water directly, but you can detect it by monitoring rate of change:

```elixir
def find_slack_water(station, date) do
  {:ok, predictions} = Tidewave.predict_range(
    station: station,
    start: DateTime.new!(date, ~T[00:00:00]),
    end: DateTime.new!(date, ~T[23:59:59]),
    interval: :minute
  )

  predictions
  |> Enum.chunk_every(2, 1)
  |> Enum.filter(fn [p1, p2] ->
    abs(p2.height - p1.height) < 0.01  # Very small change
  end)
end
```

---

**Version:** 0.6.1  
**Source:** https://hexdocs.pm/tidewave/0.6.1  
**Generated:** 2026-06-22
