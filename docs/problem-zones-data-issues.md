# Data Issues Summary for Problem Zones

**Date**: 2025-12-10 (test date)
**Analysis**: Zones that fail UC due to missing data

## Root Cause Analysis

The `get_generators()` function filters by `area_type_code IN ('BZN', 'BZN/CTA')` to get bidding zone generators. Several zones fail because their data uses different area type codes.

| Zone | Generators | Load Forecast | Issue |
|------|------------|---------------|-------|
| **BY** | ❌ None | ❌ None | No data in ENTSO-E (Belarus not EU) |
| **DE_50HzT** | 128 (CTA) | 96 (CTA) | TSO control area, not bidding zone. Use DE_LU instead. |
| **DK** | 74 (CTA) | 48 (CTA/CTY) | Country-level, not bidding zone. Use DK1/DK2 instead. |
| **GB** | 510 (BZN/CTA) | ❌ None | Post-Brexit: no day-ahead load forecast in DB |
| **HR** | ❌ None | 96 (BZN/CTA/CTY) | No generators registered in ENTSO-E for Croatia |
| **IT** | 3802 (CTA) | 96 (CTA/CTY) | Country-level. Use IT-NORTH, IT-SOUTH, etc. |
| **IT-SACODC** | ❌ None | ❌ None | DC interconnector zone (no generation) |
| **PLC** | ❌ None | ❌ None | Polish control area sub-zone (no data) |
| **RU_KGD** | ❌ None | ❌ None | Kaliningrad (Russia, not EU) |

## Categories

### 1. Country/TSO aggregates (should use sub-zones instead)

- `DE_50HzT` → Use `DE_LU` (Germany-Luxembourg bidding zone)
- `DK` → Use `DK1`, `DK2` (West/East Denmark)
- `IT` → Use `IT-NORTH`, `IT-SOUTH`, `IT-CSOUTH`, `IT-Calabria`, `IT-Sicily`, `IT-Sardinia`

### 2. Missing load forecast data

- `GB` - Has generators (510 units, 142 GW) but no load forecast. Would need to add GB load data to DB.

### 3. Missing generator data

- `HR` - Has load but no generators. Croatian generators may be registered under different codes or missing from ENTSO-E.

### 4. Outside EU/No data

- `BY` (Belarus), `RU_KGD` (Kaliningrad), `PLC`, `IT-SACODC` - No ENTSO-E data available.

## Technical Details

### Generator Query Filter
```sql
WHERE area_type_code IN ('BZN', 'BZN/CTA')
```

### Load Forecast Query Filter
```sql
WHERE area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
```

### Area Type Codes
- `BZN` - Bidding Zone
- `CTA` - Control Area (TSO level)
- `CTY` - Country
- Combined codes indicate overlapping definitions
