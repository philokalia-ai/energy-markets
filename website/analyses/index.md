# Methodology

The Euphemia market clearing engine combines several modelling stages to simulate European day-ahead electricity prices. Each stage involves methodological choices informed by real data patterns. The pages below document these methods in detail.

## Generator Parameter Inference

ENTSO-E provides basic generator metadata (capacity, fuel type), but operational parameters like ramp rates, minimum stable generation, and cycling constraints are not published. We infer these plant-specific parameters from 12 months of historical generation data.

[Read more &rarr;](/analyses/parameter-inference)

## Gas Plant Classification

ENTSO-E classifies all gas-fired generators under a single "Fossil Gas" fuel type, but CCGTs, CHPs, and OCGTs have very different efficiencies and operating characteristics. We implement a two-stage classification pipeline that first uses naming patterns, then validates with historical behaviour.

[Read more &rarr;](/analyses/gas-classification)
