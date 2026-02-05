# Unknown "Other" Generators

This document lists generators classified as "Other" fuel type in the ENTSO-E database that need manual review to determine their actual technology type.

**Date queried:** 2025-12-10
**Total units:** 31 (excluding BESS units which are auto-reclassified to "Energy storage")

## Summary by Zone

| Zone | Count | Total Capacity (MW) |
|------|-------|---------------------|
| FI | 1 | 125 |
| GB | 5 | 1,101 |
| HU | 12 | 115.3 |
| IT-* | 12 | 2,330 |
| NL | 1 | 144 |

## FI (Finland)

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| Raahen Voima | 44W-00000000016I | Raahe | 125.0 | Likely industrial CHP |

## GB (Great Britain)

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| IRNPS-2 | 48W00000IRNPS-2S | GB | 500.0 | Possibly interconnector or pumped storage |
| IRNPS-1 | 48W00000IRNPS-1U | GB | 500.0 | Possibly interconnector or pumped storage |
| MARK-1 | 48W000000MARK-1D | GB | 55.0 | Unknown |
| STCR-1 | 48W000000STCR-1F | GB | 45.0 | Unknown |
| VPI-TRABMU | 48WVPI-TRAD-BMUI | GB | 1.0 | Possibly VPP (Virtual Power Plant) |

## HU (Hungary)

All Hungarian "Other" units appear to be small distributed resources, possibly aggregated portfolios or VPPs. The naming pattern suggests they are aggregator entities (suffix "ae" = aggregated entity?).

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| DUMBBSBae | 15W-DUMBBSB-AE-K | Százhalombatta | 20.0 | Aggregated entity |
| SENYBSBae | 15W-SENYBSB-AE-L | Sény | 20.0 | Aggregated entity |
| SZOLGBBae | 15W-SZOLGBB-AE-D | Budapest | 20.0 | Aggregated entity |
| METAGABae | 15W-METAGAB-AE-2 | Százhalombatta | 19.5 | Aggregated entity |
| DUMCBSBae | 15W-DUMCBSB-AE-B | Százhalombatta | 10.0 | Aggregated entity |
| DUMDBSBae | 15W-DUMDBSB-AE-2 | Százhalombatta | 10.0 | Aggregated entity |
| ALPIQ1ae | 15WALPIQG2--VPP8 | Budapest | 6.5 | VPP (code contains "VPP") |
| LITRABBae | 15W-LITRABB-AE-6 | Litér | 5.5 | Aggregated entity |
| GYHALBBae | 15W-GYHALBB-AE-1 | Gyöngyöshalász | 1.5 | Aggregated entity |
| OMNRBABae | 15W-OMNRBAB-AE-M | Szarvas | 1.0 | Aggregated entity |
| LITRBBBae | 15W-LITRBBB-AE-Z | Litér | 0.8 | Aggregated entity |
| SINRBCBae | 15W-SINRBCB-AE-4 | Szarvas | 0.5 | Aggregated entity |

## IT (Italy)

Italian "Other" units have cryptic names (UP_OEEPSNL_* pattern). These need research with Italian TSO (Terna) data.

### IT-Calabria

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| UP_OEEPSNL_31775 | 26WOEEPSNL31775R | N/A | 100.0 | Unknown |

### IT-CSOUTH

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| UP_OEEPSNL_31753 | 26WOEEPSNL317530 | N/A | 145.0 | Unknown |
| UP_OEEPSNL_31841 | 26WOEEPSNL318413 | N/A | 100.0 | Unknown |
| UP_OEEPSNL_31770 | 26WOEEPSNL317700 | N/A | 100.0 | Unknown |

### IT-NORTH

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| UP_OEEPSNL_31611 | 26WOEEPSNL31611K | N/A | 840.0 | **Large unit - priority research** |
| UP_OEEPSNL_31781 | 26WOEEPSNL31781W | N/A | 200.0 | Unknown |

### IT-Sardinia

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| UP_OEEPSNL_31754 | 26WOEEPSNL31754Z | N/A | 200.0 | Unknown |
| UP_OEEPSNL_31757 | 26WOEEPSNL31757T | N/A | 180.0 | Unknown |
| UP_OEEPSNL_31748 | 26WOEEPSNL31748U | N/A | 140.0 | Unknown |

### IT-Sicily

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| UP_107698_31815 | 26W107698318150B | N/A | 195.0 | Unknown |

### IT-SOUTH

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| UP_133601_31850 | 26W1336013185007 | N/A | 200.0 | Unknown |
| UP_OEEPSNL_31768 | 26WOEEPSNL31768O | N/A | 110.0 | Unknown |

## NL (Netherlands)

| Name | Code | Location | Capacity (MW) | Notes |
|------|------|----------|---------------|-------|
| IJmond | 49W000000000021B | intra_zonal | 144.0 | Industrial site, possibly steel/metal |

## Priority for Research

1. **IT-NORTH UP_OEEPSNL_31611** (840 MW) - Largest unknown unit
2. **GB IRNPS-1/2** (2x 500 MW) - Large units, possibly pumped storage
3. **Italian UP_OEEPSNL_*** units - Total ~2 GW across zones
4. **NL IJmond** (144 MW) - Industrial site

## Current Handling

These generators are currently treated with flexible "Other" fuel type parameters:
- Startup time: 1-2 hours
- Ramp rate: 50%/hour
- Min load factor: 0%
- Min uptime/downtime: 1 hour

This is a conservative approach that allows flexibility but may not accurately model thermal constraints if these are actually conventional power plants.

## TODO

- [ ] Research GB IRNPS units (interconnectors? pumped storage?)
- [ ] Contact Terna for Italian UP_OEEPSNL classification
- [ ] Investigate HU aggregated entities for VPP classification
- [ ] Check if IJmond is steel industry CHP
- [ ] Add name patterns to `infer_fuel_type_from_name()` as units are identified
